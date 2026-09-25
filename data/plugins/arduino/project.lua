-- Creating new Arduino projects: a sketch folder with a build profile (sketch.yaml).
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local cli = require "plugins.arduino.cli"

local project = {}

local STORAGE_MODULE, OPEN_AFTER_RESTART_KEY = "arduino", "open-after-restart"

-- boards of the installed platforms, loaded once per session
local boards_cache


-- Loads the installed boards as { name, fqbn } sorted by name; must be called from a thread.
local function load_boards()
  if boards_cache then return boards_cache end
  local result, err = cli.run_json({ "board", "listall" })
  if not result then return nil, err end
  local boards = {}
  for _, board in ipairs(result.boards or {}) do
    if type(board.fqbn) == "string" then
      table.insert(boards, { name = board.name or board.fqbn, fqbn = board.fqbn })
    end
  end
  table.sort(boards, function(a, b) return a.name:lower() < b.name:lower() end)
  boards_cache = boards
  return boards
end


-- Returns the sketchbook folder configured in arduino-cli; must be called from a thread.
local function sketchbook_dir()
  local dir = cli.run_json({ "config", "get", "directories.user" })
  if type(dir) == "string" and dir ~= "" then return dir end
  return HOME and (HOME .. PATHSEP .. "Arduino")
end


---Profile name derived from a board, e.g. "arduino:avr:uno" -> "uno".
---@param fqbn string
---@return string
function project.profile_name(fqbn)
  local board_id = fqbn:match("^[^:]+:[^:]+:([^:]+)") or fqbn
  local name = board_id:gsub("[^%w_%-]", "_")
  return name
end


-- Creates the sketch and its profile, then opens it; must be called from a thread.
local function create(path, board)
  local name = common.basename(path)
  core.log("Creating project %s for %s...", name, board.name)
  local _, err = cli.run_json({ "sketch", "new", path })
  if err then
    core.error("Could not create project: %s", err)
    return
  end
  local profile = project.profile_name(board.fqbn)
  _, err = cli.run_json({ "profile", "create", "--profile", profile, "--fqbn", board.fqbn, "--set-default", path })
  if err then
    core.error("Created %s, but could not add the %s build profile: %s", name, board.name, err)
  else
    core.log("Created project %s for %s", name, board.name)
  end
  -- the editor restarts when switching project; open the sketch once it is back
  storage.save(STORAGE_MODULE, OPEN_AFTER_RESTART_KEY, { file = path .. PATHSEP .. name .. ".ino" })
  core.confirm_close_docs(core.docs, core.open_project, path)
end


-- fuzzy matching uses tostring() to match (so typing matches both the name and
-- the FQBN) and `<` to order items with the same score
local board_item_mt = {
  __tostring = function(item) return item.text .. " " .. item.info end,
  __lt = function(a, b) return tostring(a) < tostring(b) end,
}

-- Orders boards for the typed text: exact board id or name first, then names with
-- a word starting with the text, then any that contain it, then fuzzy matches.
-- Plain fuzzy matching alone would rank e.g. "Arduino BT" above "Arduino UNO" for
-- "uno", because the letters u-n-o also appear in "arduino".
local function rank_boards(items, text)
  local needle = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if needle == "" then return items end
  local word_start = "%f[%w]" .. needle:gsub("%p", "%%%0")
  local groups = { {}, {}, {} }
  local ranked = {}
  for _, item in ipairs(items) do
    local name, fqbn = item.text:lower(), item.info:lower()
    local id = project.profile_name(fqbn)
    local group
    if id == needle or name == needle or fqbn == needle then
      group = 1
    elseif id:sub(1, #needle) == needle or name:find(word_start) then
      group = 2
    elseif name:find(needle, 1, true) or fqbn:find(needle, 1, true) then
      group = 3
    end
    if group then
      table.insert(groups[group], item)
      ranked[item] = true
    end
  end
  local result = {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group) do table.insert(result, item) end
  end
  for _, item in ipairs(common.fuzzy_match(items, text)) do
    if not ranked[item] then table.insert(result, item) end
  end
  return result
end


local function choose_board(path, boards)
  local items = {}
  for _, board in ipairs(boards) do
    table.insert(items, setmetatable({ text = board.name, info = board.fqbn, board = board }, board_item_mt))
  end
  core.command_view:enter("Board for " .. common.basename(path), {
    submit = function(text, item)
      local board = item and item.board
      if not board then
        for _, b in ipairs(boards) do
          if b.fqbn == text or b.name == text then board = b break end
        end
      end
      if not board then
        core.error("Unknown board: %s", text)
        return
      end
      core.add_thread(create, nil, path, board)
    end,
    suggest = function(text)
      return rank_boards(items, text)
    end,
  })
end


local function choose_location(sketchbook, boards)
  core.command_view:enter("New Project", {
    text = sketchbook and (common.home_encode(sketchbook) .. PATHSEP) or "",
    submit = function(text)
      local path = common.home_expand(text):gsub("[/\\]+$", "")
      choose_board(path, boards)
    end,
    suggest = function(text)
      return common.home_encode_list(common.dir_path_suggest(common.home_expand(text), sketchbook or HOME))
    end,
    validate = function(text)
      local path = common.home_expand(text):gsub("[/\\]+$", "")
      local name = common.basename(path)
      if not name or name == "" or path == common.home_expand(sketchbook or "") then
        core.error("Type a name for the project")
        return false
      end
      if system.get_file_info(path) then
        core.error("%s already exists", common.home_encode(path))
        return false
      end
      local parent = common.dirname(path)
      local parent_info = parent and system.get_file_info(parent)
      if parent_info and parent_info.type ~= "dir" then
        core.error("%s is not a folder", common.home_encode(parent))
        return false
      end
      return true
    end,
  })
end


---Asks for a project location and a board, then creates and opens the project.
function project.new()
  if cli.status ~= "ok" then
    core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
    return
  end
  core.add_thread(function()
    local boards, err = load_boards()
    if not boards then
      core.error("Could not list boards: %s", err)
      return
    end
    if #boards == 0 then
      core.error("No boards are installed; install a platform first (arduino-cli core install ...)")
      return
    end
    choose_location(sketchbook_dir(), boards)
  end)
end


---Opens the sketch remembered by `create` before the restart, if any.
function project.open_pending()
  local pending = storage.load(STORAGE_MODULE, OPEN_AFTER_RESTART_KEY)
  if not pending then return end
  storage.clear(STORAGE_MODULE, OPEN_AFTER_RESTART_KEY)
  local file = type(pending) == "table" and pending.file
  if type(file) ~= "string" or not system.get_file_info(file) then return end
  core.add_thread(function()
    core.root_view:open_doc(core.open_doc(file))
  end)
end


return project
