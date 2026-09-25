-- Creating new Arduino projects: a sketch folder with a build profile (sketch.yaml).
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local cli = require "plugins.arduino.cli"

local project = {}

local STORAGE_MODULE, OPEN_AFTER_RESTART_KEY = "arduino", "open-after-restart"

---A board of an installed platform.
---@class arduino.board
---@field name string e.g. "Arduino UNO"
---@field fqbn string e.g. "arduino:avr:uno"
---@field vendor string e.g. "arduino"
---@field vendor_name string e.g. "Arduino"
---@field arch string Platform id, e.g. "arduino:avr"
---@field arch_name string e.g. "Arduino AVR Boards"
---@field version string Installed platform version, e.g. "1.8.8"

-- boards of the installed platforms, loaded once per session
local boards_cache


---Loads the boards of the installed platforms, sorted by name.
---Must be called from a thread (see `core.add_thread`).
---@return arduino.board[]? boards
---@return string? error
function project.load_boards()
  if boards_cache then return boards_cache end
  local result, err = cli.run_json({ "board", "listall" })
  if not result then return nil, err end
  local boards = {}
  for _, board in ipairs(result.boards or {}) do
    local vendor, arch
    if type(board.fqbn) == "string" then
      vendor, arch = board.fqbn:match("^([^:]+):([^:]+):")
    end
    if vendor then
      local platform = board.platform or {}
      local metadata, release = platform.metadata or {}, platform.release or {}
      table.insert(boards, {
        name = board.name or board.fqbn,
        fqbn = board.fqbn,
        vendor = vendor,
        vendor_name = metadata.maintainer or vendor,
        arch = vendor .. ":" .. arch,
        arch_name = release.name or (vendor .. ":" .. arch),
        version = release.version or "",
      })
    end
  end
  table.sort(boards, function(a, b) return a.name:lower() < b.name:lower() end)
  boards_cache = boards
  return boards
end


---Returns the sketchbook folder configured in arduino-cli.
---Must be called from a thread (see `core.add_thread`).
---@return string?
function project.sketchbook_dir()
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


---Explains what is wrong with a project name, or returns nil when it is valid.
---Mirrors the sketch name rules of arduino-cli.
---@param name string
---@return string?
function project.name_problem(name)
  if name == "" then return "Type a name for your project" end
  if #name > 63 then return "The name can be at most 63 characters long" end
  if not name:match("^[%w_]") then return "The name must start with a letter, a number or _" end
  if name:find("%s") then return "Spaces are not allowed; use _ or - instead" end
  if name:find("[^%w_%-%.]") then return "Only letters, numbers, _ - and . are allowed" end
  if name:sub(-1) == "." then return "The name cannot end with ." end
end


---Creates the sketch at `path` with a default build profile for `board`.
---Must be called from a thread (see `core.add_thread`).
---@param path string
---@param board arduino.board
---@return boolean created
---@return string? error
function project.create(path, board)
  local name = common.basename(path)
  local _, err = cli.run_json({ "sketch", "new", path })
  if err then return false, err end
  local profile = project.profile_name(board.fqbn)
  _, err = cli.run_json({ "profile", "create", "--profile", profile, "--fqbn", board.fqbn, "--set-default", path })
  if err then
    core.error("Created %s, but could not add the %s build profile: %s", name, board.name, err)
  else
    core.log("Created project %s for %s", name, board.name)
  end
  return true
end


---Opens a newly created project, and its sketch once the editor has restarted.
---@param path string
function project.open(path)
  storage.save(STORAGE_MODULE, OPEN_AFTER_RESTART_KEY, { file = path .. PATHSEP .. common.basename(path) .. ".ino" })
  core.confirm_close_docs(core.docs, core.open_project, path)
end


---Opens the sketch remembered by `project.open` before the restart, if any.
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
