-- Locates the arduino-cli executable, remembers its location and checks that it works.
local core = require "core"
local storage = require "core.storage"

local cli = {}

---Where to learn how to install arduino-cli.
cli.INSTALL_URL = "https://arduino.github.io/arduino-cli/latest/installation/"

---File name of the executable on this platform.
cli.EXE_NAME = PLATFORM == "Windows" and "arduino-cli.exe" or "arduino-cli"

local STORAGE_MODULE, STORAGE_KEY = "arduino", "cli"
local CHECK_TIMEOUT = 15

---@alias arduino.cli.status
---| "checking"  # running the configured executable to get its version
---| "ok"        # the executable works; `cli.version` is set
---| "missing"   # the configured file does not exist anymore
---| "broken"    # the file exists but did not report a version; `cli.error` is set
---| "not_found" # no location is configured and none was found on this computer

---Configured location of the executable, if any.
---@type string?
cli.path = nil
---@type arduino.cli.status
cli.status = "checking"
---Version reported by the executable when `status` is "ok".
---@type string?
cli.version = nil
---Why the executable is not usable when `status` is "broken".
---@type string?
cli.error = nil

-- incremented on every check so results of outdated checks are ignored
local check_id = 0


local function is_file(path)
  local info = path and system.get_file_info(path)
  return info ~= nil and info.type == "file"
end


---Directories searched for a globally installed arduino-cli, in order.
---@return string[]
function cli.search_dirs()
  local dirs = {}
  local list_sep = PLATFORM == "Windows" and ";" or ":"
  for dir in (os.getenv("PATH") or ""):gmatch("[^" .. list_sep .. "]+") do
    table.insert(dirs, dir)
  end
  -- common install locations that are not always on PATH (e.g. for desktop launchers)
  if PLATFORM == "Windows" then
    local program_files = os.getenv("ProgramFiles")
    if program_files then table.insert(dirs, program_files .. "\\Arduino CLI") end
  else
    if HOME then
      table.insert(dirs, HOME .. "/bin")
      table.insert(dirs, HOME .. "/.local/bin")
    end
    table.insert(dirs, "/usr/local/bin")
    table.insert(dirs, "/opt/homebrew/bin")
    table.insert(dirs, "/snap/bin")
  end
  return dirs
end


---Looks for a globally installed arduino-cli.
---@return string? path
function cli.find_global()
  for _, dir in ipairs(cli.search_dirs()) do
    local path = dir .. PATHSEP .. cli.EXE_NAME
    if is_file(path) then return path end
  end
end


-- Runs `arduino-cli version`; must be called from a thread.
local function read_version(path)
  local ok, proc = pcall(process.start, { path, "version", "--format", "json" }, {
    stdin = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_STDOUT,
  })
  if not ok then return nil, tostring(proc) end
  -- Read until the process exits. We can't use stream:read("all") because reads
  -- keep returning "" instead of nil after the process has exited.
  local chunks = {}
  local deadline = system.get_time() + CHECK_TIMEOUT
  while true do
    local running = proc:running()
    local chunk = proc:read_stdout(4096)
    if chunk and #chunk > 0 then
      table.insert(chunks, chunk)
    elseif not chunk or not running then
      break
    elseif system.get_time() > deadline then
      proc:kill()
      return nil, "no response within " .. CHECK_TIMEOUT .. " seconds"
    else
      coroutine.yield(0.05)
    end
  end
  local output = table.concat(chunks)
  local exit_code = proc:returncode()
  local version = output:match('"VersionString"%s*:%s*"([^"]+)"')
  if exit_code == 0 and version then return version end
  local message = output:gsub("%s+$", ""):match("[^\n]*$")
  return nil, (message ~= "" and message) or ("exited with code " .. tostring(exit_code))
end


---Checks that the configured executable exists and works, updating `cli.status`.
---Existence is checked right away; running it happens in the background.
function cli.check()
  check_id = check_id + 1
  local id = check_id
  local path = cli.path
  cli.version, cli.error = nil, nil
  core.redraw = true
  if not path then
    cli.status = "not_found"
    return
  end
  if not is_file(path) then
    cli.status = "missing"
    core.warn("arduino-cli not found at %s", path)
    return
  end
  cli.status = "checking"
  core.add_thread(function()
    local version, err = read_version(path)
    if id ~= check_id then return end
    if version then
      cli.status, cli.version = "ok", version
      core.log_quiet("Using arduino-cli %s at %s", version, path)
    else
      cli.status, cli.error = "broken", err
      core.warn("arduino-cli at %s is not working: %s", path, err)
    end
    core.redraw = true
  end)
end


---Uses the executable at `path` from now on, remembering it for future runs.
---@param path string
function cli.set_path(path)
  cli.path = path
  storage.save(STORAGE_MODULE, STORAGE_KEY, { path = path })
  cli.check()
end


---Searches for a globally installed arduino-cli and uses it if found.
---@return string? path The location found, if any.
function cli.search()
  local path = cli.find_global()
  if path then
    cli.set_path(path)
  elseif not cli.path then
    cli.check()
  end
  return path
end


---Loads the remembered location, or searches for one if none is remembered yet.
function cli.init()
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  if type(saved) == "table" and type(saved.path) == "string" then
    cli.path = saved.path
    cli.check()
  else
    cli.search()
  end
end


return cli
