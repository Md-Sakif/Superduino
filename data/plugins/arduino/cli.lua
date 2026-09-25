-- Locates the arduino-cli executable, remembers its location and checks that it works.
local core = require "core"
local storage = require "core.storage"
local json = require "plugins.arduino.json"

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

---Functions called after every check finishes, e.g. to refresh things that use arduino-cli.
---@type fun()[]
cli.on_checked = {}

local function notify_checked()
  for _, fn in ipairs(cli.on_checked) do core.try(fn) end
end


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


---Starts an arduino-cli command without waiting for it.
---@param args string[] Arguments passed to arduino-cli.
---@param options? { path?: string } `path` defaults to `cli.path`.
---@return process? proc
---@return string? error
function cli.start(args, options)
  local path = (options and options.path) or cli.path
  if not path then return nil, "arduino-cli is not configured" end
  local command = { path }
  for _, arg in ipairs(args) do table.insert(command, arg) end
  local ok, proc = pcall(process.start, command, { stdin = process.REDIRECT_DISCARD })
  if not ok then return nil, tostring(proc) end
  return proc
end


---Runs an arduino-cli command and collects its output.
---Must be called from a thread (see `core.add_thread`).
---@param args string[] Arguments passed to arduino-cli.
---@param options? { path?: string, timeout?: number } `path` defaults to `cli.path`.
---@return string? stdout nil when the process could not be started or timed out
---@return string stderr_or_error
---@return integer? exit_code
function cli.run(args, options)
  options = options or {}
  local proc, start_err = cli.start(args, options)
  if not proc then return nil, start_err end
  -- Read until the process exits. We can't use stream:read("all") because reads
  -- keep returning "" instead of nil after the process has exited.
  local out, err = {}, {}
  local deadline = options.timeout and system.get_time() + options.timeout
  while true do
    local running = proc:running()
    local out_chunk = proc:read_stdout(4096)
    local err_chunk = proc:read_stderr(4096)
    if out_chunk and #out_chunk > 0 then table.insert(out, out_chunk) end
    if err_chunk and #err_chunk > 0 then table.insert(err, err_chunk) end
    local got_data = (out_chunk and #out_chunk > 0) or (err_chunk and #err_chunk > 0)
    if not got_data then
      if not running or (not out_chunk and not err_chunk) then break end
      if deadline and system.get_time() > deadline then
        proc:kill()
        return nil, "no response within " .. options.timeout .. " seconds"
      end
      coroutine.yield(0.05)
    end
  end
  return table.concat(out), table.concat(err), proc:returncode()
end


---Runs an arduino-cli command with `--json` and decodes its output.
---Must be called from a thread (see `core.add_thread`).
---@param args string[]
---@param options? { path?: string, timeout?: number }
---@return any? result Decoded output when the command succeeded.
---@return string? error Message explaining the failure otherwise.
function cli.run_json(args, options)
  local json_args = { table.unpack(args) }
  table.insert(json_args, "--json")
  local stdout, stderr, exit_code = cli.run(json_args, options)
  if not stdout then return nil, stderr end
  local result = json.decode(stdout)
  if exit_code == 0 and result ~= nil then return result end
  if type(result) == "table" and type(result.error) == "string" then
    return nil, result.error
  end
  local message = (stderr ~= "" and stderr or stdout):gsub("%s+$", ""):match("[^\n]*$")
  return nil, (message ~= "" and message) or ("exited with code " .. tostring(exit_code))
end


-- Asks the executable at `path` for its version; must be called from a thread.
local function read_version(path)
  local result, err = cli.run_json({ "version" }, { path = path, timeout = CHECK_TIMEOUT })
  if not result then return nil, err end
  if type(result.VersionString) ~= "string" then return nil, "did not report a version" end
  return result.VersionString
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
    notify_checked()
    return
  end
  if not is_file(path) then
    cli.status = "missing"
    core.warn("arduino-cli not found at %s", path)
    notify_checked()
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
    notify_checked()
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
