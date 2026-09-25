-- USB access on Linux: membership of the serial port group (usually "dialout")
-- and the one-time setup scripts (post_install.sh) that some board platforms
-- ship to install udev rules. Both need administrator rights, which we get with
-- pkexec so the desktop shows its normal password dialog.
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local cli = require "plugins.arduino.cli"

local access = {}

local STORAGE_MODULE, SETUP_KEY = "arduino", "board-setup"

---Whether USB access needs managing on this system.
access.SUPPORTED = PLATFORM == "Linux"

---Program used to run commands as administrator; tests may replace it.
access.ADMIN_COMMAND = "pkexec"

---@alias arduino.serial_state
---| "checking"
---| "ok"       # this session can open serial ports
---| "missing"  # the user is not in the serial port group
---| "relogin"  # added to the group, but only new login sessions have it
---| "unknown"  # could not tell (e.g. no serial devices and no known group)

---@class arduino.serial_status
---@field state arduino.serial_state
---@field group? string e.g. "dialout"
---@field user? string

---@type arduino.serial_status
access.serial = { state = access.SUPPORTED and "checking" or "ok" }

---Installed platforms whose setup script has not been run, as
---{ id, name, version, script, skipped }.
access.pending_setups = {}


-- Runs a command and returns its output and exit code; must be called from a thread.
local function run(command, options)
  local ok, proc = pcall(process.start, command, {
    stdin = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_STDOUT,
    cwd = options and options.cwd,
  })
  if not ok then return nil, tostring(proc) end
  local out = {}
  while true do
    local running = proc:running()
    local chunk = proc:read_stdout(4096)
    if chunk and #chunk > 0 then
      table.insert(out, chunk)
    elseif not chunk or not running then
      break
    else
      coroutine.yield(0.1)
    end
  end
  return table.concat(out), proc:returncode()
end


local function find_program(name, dirs)
  for _, dir in ipairs(dirs) do
    local path = dir .. "/" .. name
    if system.get_file_info(path) then return path end
  end
end


---The administrator helper, if available.
---@return string?
function access.admin_program()
  if access.ADMIN_COMMAND:find("/") then
    return system.get_file_info(access.ADMIN_COMMAND) and access.ADMIN_COMMAND or nil
  end
  return find_program(access.ADMIN_COMMAND, { "/usr/bin", "/bin", "/usr/local/bin" })
end


---Runs a command as administrator, showing the desktop's password dialog.
---Must be called from a thread.
---@param command string[]
---@param options? { cwd?: string }
---@return "ok"|"cancelled"|"failed"|"unavailable" result
---@return string output
function access.run_as_admin(command, options)
  local admin = access.admin_program()
  if not admin then return "unavailable", "" end
  local full = { admin }
  for _, arg in ipairs(command) do table.insert(full, arg) end
  local output, code = run(full, options)
  if not output then return "failed", code or "" end
  -- pkexec: 126 = the dialog was dismissed or not authorized, 127 = authentication failed
  if code == 0 then return "ok", output end
  if code == 126 then return "cancelled", output end
  return "failed", output
end


---The command a user could run in a terminal instead of using pkexec.
---@param command string[]
---@return string
function access.terminal_command(command)
  local quoted = {}
  for _, arg in ipairs(command) do
    table.insert(quoted, arg:find("[^%w%-%./_:=]") and ("'" .. arg:gsub("'", "'\\''") .. "'") or arg)
  end
  return "sudo " .. table.concat(quoted, " ")
end


-------------------------------------------------------------------------------
-- Serial port group
-------------------------------------------------------------------------------

-- Group that owns serial devices, e.g. "dialout" (Debian, Ubuntu, Fedora) or "uucp" (Arch).
local function serial_group()
  for _, device in ipairs({ "/dev/ttyACM0", "/dev/ttyUSB0", "/dev/ttyS0" }) do
    if system.get_file_info(device) then
      local output, code = run({ "stat", "-c", "%G", device })
      local group = code == 0 and output and output:match("^%s*(%S+)")
      if group and group ~= "root" then return group end
    end
  end
  local fp = io.open("/etc/group")
  local groups = fp and fp:read("a") or ""
  if fp then fp:close() end
  for _, name in ipairs({ "dialout", "uucp" }) do
    if groups:find("\n" .. name .. ":", 1, true) or groups:find("^" .. name .. ":") then return name end
  end
end


-- Whether /etc/group lists `user` as a member of `group`.
local function listed_in_group(group, user)
  local fp = io.open("/etc/group")
  if not fp then return false end
  for line in fp:lines() do
    local name, members = line:match("^([^:]*):[^:]*:[^:]*:(.*)$")
    if name == group then
      fp:close()
      for member in members:gmatch("[^,%s]+") do
        if member == user then return true end
      end
      return false
    end
  end
  fp:close()
  return false
end


---Checks whether this session can open serial ports. Must be called from a thread.
function access.check_serial()
  if not access.SUPPORTED then return end
  local user_out = run({ "id", "-un" })
  local groups_out = run({ "id", "-nG" })
  local user = user_out and user_out:match("%S+") or os.getenv("USER")
  local group = serial_group()
  local status = { user = user, group = group }
  if user == "root" then
    status.state = "ok"
  elseif not group then
    status.state = "unknown"
  elseif groups_out and (" " .. groups_out .. " "):find("%s" .. group:gsub("%p", "%%%0") .. "%s") then
    status.state = "ok"
  elseif user and listed_in_group(group, user) then
    status.state = "relogin"
  else
    status.state = "missing"
  end
  access.serial = status
  core.redraw = true
end


---Command that adds the user to the serial port group.
---@return string[]?
function access.serial_fix_command()
  local s = access.serial
  if not s.group or not s.user then return nil end
  local usermod = find_program("usermod", { "/usr/sbin", "/sbin", "/usr/bin" }) or "usermod"
  return { usermod, "-aG", s.group, s.user }
end


---Adds the user to the serial port group. Must be called from a thread.
---@return "ok"|"cancelled"|"failed"|"unavailable" result
---@return string output
function access.fix_serial()
  local command = access.serial_fix_command()
  if not command then return "failed", "could not tell which group owns the serial ports" end
  local result, output = access.run_as_admin(command)
  access.check_serial()
  return result, output
end


-------------------------------------------------------------------------------
-- Board setup scripts
-------------------------------------------------------------------------------

local function setup_records()
  local records = storage.load(STORAGE_MODULE, SETUP_KEY)
  return type(records) == "table" and records or {}
end


---What happened to a platform's setup script: "done", "skipped" or nil.
---@param id string
---@param version string
---@return string?
function access.setup_record(id, version)
  return setup_records()[id .. "@" .. version]
end


---Records what happened to a platform's setup script: "done" or "skipped".
---@param id string
---@param version string
---@param result "done"|"skipped"
function access.record_setup(id, version, result)
  local records = setup_records()
  records[id .. "@" .. version] = result
  storage.save(STORAGE_MODULE, SETUP_KEY, records)
end


---Path of a platform's setup script, if it has one. Must be called from a thread.
---@param id string e.g. "arduino:renesas_uno"
---@param version string
---@return string?
function access.setup_script(id, version)
  if not access.SUPPORTED then return nil end
  local data_dir = cli.run_json({ "config", "get", "directories.data" })
  local vendor, arch = id:match("^([^:]+):(.+)$")
  if type(data_dir) ~= "string" or not vendor then return nil end
  local script = table.concat({ data_dir, "packages", vendor, "hardware", arch, version, "post_install.sh" }, PATHSEP)
  return system.get_file_info(script) and script or nil
end


---Finds installed platforms whose setup script has not been run yet.
---Must be called from a thread.
function access.check_setups()
  if not access.SUPPORTED then return end
  local result = cli.run_json({ "core", "list" })
  local records = setup_records()
  local pending = {}
  for _, p in ipairs(type(result) == "table" and result.platforms or {}) do
    local version = p.installed_version
    if type(p.id) == "string" and type(version) == "string" and version ~= "" then
      local record = records[p.id .. "@" .. version]
      if record ~= "done" then
        local script = access.setup_script(p.id, version)
        if script then
          local release = (p.releases or {})[version] or {}
          table.insert(pending, { id = p.id, name = release.name or p.id, version = version,
            script = script, skipped = record == "skipped" })
        end
      end
    end
  end
  access.pending_setups = pending
  core.redraw = true
end


---Runs a platform's setup script as administrator. Must be called from a thread.
---@param setup { id: string, version: string, script: string }
---@return "ok"|"cancelled"|"failed"|"unavailable" result
---@return string output
function access.run_setup(setup)
  local result, output = access.run_as_admin({ "/bin/bash", setup.script }, { cwd = common.dirname(setup.script) })
  if result == "ok" then
    access.record_setup(setup.id, setup.version, "done")
    core.log("Ran the setup script of %s", setup.id)
  end
  access.check_setups()
  return result, output
end


---Rechecks everything; called at startup and after changes.
function access.refresh()
  if not access.SUPPORTED then return end
  core.add_thread(function()
    access.check_serial()
    if cli.status == "ok" then access.check_setups() end
  end)
end


return access
