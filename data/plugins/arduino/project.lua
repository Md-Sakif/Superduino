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


---A board platform ("architecture") known to the Boards Manager.
---@class arduino.platform
---@field id string e.g. "arduino:esp32"
---@field vendor string e.g. "arduino"
---@field vendor_name string e.g. "Arduino"
---@field name string e.g. "Arduino ESP32 Boards"
---@field installed_version string? nil when not installed
---@field latest_version string
---@field board_names string[] Boards of the release that is (or would be) installed.
---@field deprecated boolean

local platforms_cache


---Loads all platforms of the Boards Manager index, installed or not.
---Downloads the index first when arduino-cli does not have one yet.
---Must be called from a thread (see `core.add_thread`).
---@return arduino.platform[]? platforms
---@return string? error
function project.load_platforms()
  if platforms_cache then return platforms_cache end
  local result, err = cli.run_json({ "core", "search" })
  if not result or #(result.platforms or {}) == 0 then
    -- a fresh arduino-cli has no index yet
    local _, update_err = cli.run_json({ "core", "update-index" })
    if update_err then return nil, update_err end
    result, err = cli.run_json({ "core", "search" })
    if not result then return nil, err end
  end
  local platforms = {}
  for _, p in ipairs(result.platforms or {}) do
    local vendor = type(p.id) == "string" and p.id:match("^([^:]+):")
    if vendor then
      local installed = p.installed_version ~= "" and p.installed_version or nil
      local releases = p.releases or {}
      local release = releases[installed or ""] or releases[p.latest_version or ""] or {}
      local board_names = {}
      for _, board in ipairs(release.boards or {}) do
        if type(board.name) == "string" then table.insert(board_names, board.name) end
      end
      local name = release.name or p.id
      table.insert(platforms, {
        id = p.id,
        vendor = vendor,
        vendor_name = p.maintainer or vendor,
        name = name,
        installed_version = installed,
        latest_version = p.latest_version or "",
        board_names = board_names,
        deprecated = p.deprecated == true or name:find("DEPRECATED", 1, true) ~= nil,
      })
    end
  end
  platforms_cache = platforms
  return platforms
end


---Forgets the loaded boards and platforms, e.g. after installing a platform.
function project.forget_cache()
  boards_cache, platforms_cache = nil, nil
end


---Progress reported while installing a platform.
---@class arduino.install_event
---@field kind "progress"|"downloaded"|"installing"|"installed"|"message"
---@field item? string Package being handled, e.g. "arduino:avr-gcc@7.3.0-atmel3.6.1-arduino7".
---@field done? string Downloaded amount, e.g. "5.28 MiB".
---@field total? string Download size, e.g. "25.84 MiB".
---@field percent? number
---@field eta? string Time left, e.g. "00m21s".
---@field text? string For "message" events.

-- Turns one line of `arduino-cli core install` output into an event.
local function parse_install_line(line)
  line = line:gsub("%s+$", "")
  if line == "" or line:find("^Skipping .* configuration") then return end
  local item, done, total, percent, eta = line:match("^(%S+) (.-) / (.-)%s+([%d%.]+)%%%s*(%S*)$")
  if item then
    return { kind = "progress", item = item, done = done, total = total,
      percent = tonumber(percent), eta = eta ~= "" and eta or nil }
  end
  item = line:match("^(%S+) already downloaded$") or line:match("^(%S+) downloaded$")
  if item then return { kind = "downloaded", item = item } end
  item = line:match("^Installing platform (%S+)%.%.%.$") or line:match("^Installing (%S+)%.%.%.$")
  if item then return { kind = "installing", item = item } end
  item = line:match("^Platform (%S+) installed$") or line:match("^(%S+) installed$")
  if item then return { kind = "installed", item = item } end
  return { kind = "message", text = line }
end


-------------------------------------------------------------------------------
-- Tracking installs, so that an interrupted one can be repaired
-------------------------------------------------------------------------------

local INSTALLS_KEY = "installs"

---Platforms whose installation did not finish, keyed by platform id:
---{ name, state = "installing"|"incomplete" }. "installing" means an install is
---running now, or the editor stopped while installing (treated as incomplete).
local install_records_cache
function project.install_records()
  if not install_records_cache then
    local records = storage.load(STORAGE_MODULE, INSTALLS_KEY)
    install_records_cache = type(records) == "table" and records or {}
  end
  return install_records_cache
end


local function set_install_record(id, record)
  local records = project.install_records()
  records[id] = record
  storage.save(STORAGE_MODULE, INSTALLS_KEY, records)
  core.redraw = true
end


-- installs running in this session, so they are not mistaken for interrupted ones
local running_installs = {}

---Platforms left half installed (by a cancel during the install phase, a failure
---there, or the editor stopping mid-install), as a list of { id, name }.
function project.incomplete_installs()
  local list = {}
  for id, record in pairs(project.install_records()) do
    if record.state == "incomplete" or (record.state == "installing" and not running_installs[id]) then
      table.insert(list, { id = id, name = record.name or id })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end


---Installs a platform with `arduino-cli core install`, reporting progress.
---Set `handle.cancelled = true` to stop it; the process is then killed.
---After it returns, `handle.phase` is "download" or "install" (the phase it
---reached) and `handle.details` holds arduino-cli's full error output.
---Must be called from a thread (see `core.add_thread`).
---@param id string Platform id, e.g. "arduino:esp32".
---@param handle table Receives `proc`; checked for `cancelled`. `handle.name` names the platform in records.
---@param on_event fun(event: arduino.install_event)
---@return boolean installed
---@return string? error "cancelled" when cancelled
function project.install_platform(id, handle, on_event)
  local proc, err = cli.start({ "core", "install", id })
  if not proc then return false, err end
  handle.proc, handle.phase = proc, "download"
  running_installs[id] = true
  set_install_record(id, { name = handle.name or id, state = "installing" })
  -- only an interruption after files started being unpacked leaves a broken install
  local function finish(ok, message)
    running_installs[id] = nil
    if ok or handle.phase == "download" then
      set_install_record(id, nil)
    else
      set_install_record(id, { name = handle.name or id, state = "incomplete" })
    end
    return ok, message
  end
  local function handle_event(event)
    if event.kind == "installing" then handle.phase = "install" end
    on_event(event)
  end
  local buffer, errors = "", {}
  while true do
    if handle.cancelled then
      proc:kill()
      return finish(false, "cancelled")
    end
    local running = proc:running()
    local out = proc:read_stdout(4096)
    local err_chunk = proc:read_stderr(4096)
    if err_chunk and #err_chunk > 0 then table.insert(errors, err_chunk) end
    if out and #out > 0 then
      buffer = buffer .. out
      -- progress lines are separated by \r, other lines by \n
      while true do
        local s, e = buffer:find("[\r\n]")
        if not s then break end
        local event = parse_install_line(buffer:sub(1, s - 1))
        buffer = buffer:sub(e + 1)
        if event then handle_event(event) end
      end
      -- the latest progress update is not terminated until the next one arrives
      local partial = parse_install_line(buffer)
      if partial and partial.kind == "progress" then handle_event(partial) end
    elseif not running then
      break
    else
      coroutine.yield(0.1)
    end
  end
  if buffer ~= "" then
    local event = parse_install_line(buffer)
    if event then handle_event(event) end
  end
  if proc:returncode() ~= 0 then
    handle.details = table.concat(errors):gsub("%s+$", "")
    local message = handle.details:match("[^\n]*$")
    return finish(false, (message ~= "" and message) or ("arduino-cli exited with code " .. tostring(proc:returncode())))
  end
  return finish(true)
end


---Repairs a half installed platform: uninstalls what is there, then installs it again.
---Same arguments and results as `project.install_platform`.
function project.repair_platform(id, handle, on_event)
  on_event({ kind = "message", text = "Removing the incomplete installation..." })
  -- fails harmlessly when nothing was registered as installed yet
  cli.run({ "core", "uninstall", id })
  if handle.cancelled then return false, "cancelled" end
  return project.install_platform(id, handle, on_event)
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


-------------------------------------------------------------------------------
-- Creating projects
-------------------------------------------------------------------------------

---Creates the sketch at `path` with a default build profile for `board`.
---The parent folder must exist:
---arduino-cli would silently create missing folders.
---Must be called from a thread (see `core.add_thread`).
---@param path string
---@param board arduino.board
---@return boolean created
---@return string? error
function project.create(path, board)
  local name = common.basename(path)
  local parent = common.dirname(path)
  local parent_info = parent and system.get_file_info(parent)
  if not parent_info or parent_info.type ~= "dir" then
    return false, "the folder " .. tostring(parent) .. " does not exist"
  end
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
