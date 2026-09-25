-- Downloads arduino-cli into Superduino's own folder ("managed by Superduino"),
-- verifies its checksum and switches to it. Users can instead point Superduino
-- at their own arduino-cli (see cli.lua).
local core = require "core"
local common = require "core.common"
local cli = require "plugins.arduino.cli"

local managed = {}

-- Where releases are found. Tests replace these with file:// URLs.
---Page that redirects to the latest stable release (not the rate-limited GitHub API).
managed.LATEST_URL = "https://github.com/arduino/arduino-cli/releases/latest"
---Archives, served by Arduino: <base>/arduino-cli_<version>_<suffix>
managed.DOWNLOAD_BASE = "https://downloads.arduino.cc/arduino-cli"
---Checksums, published with each release: <base>/v<version>/<version>-checksums.txt
managed.RELEASE_BASE = "https://github.com/arduino/arduino-cli/releases/download"

---@alias arduino.managed_state "idle"|"checking"|"downloading"|"verifying"|"installing"|"failed"

---@type { state: arduino.managed_state, version?: string, done?: number, total?: number, error?: string, details?: string }
managed.status = { state = "idle" }

local handle -- the running download, so it can be cancelled


---Folder holding the managed arduino-cli.
function managed.dir()
  local base
  if PLATFORM == "Windows" then
    base = (os.getenv("LOCALAPPDATA") or HOME) .. "\\Superduino"
  elseif PLATFORM == "Mac OS X" then
    base = HOME .. "/Library/Application Support/Superduino"
  else
    base = (os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share")) .. "/superduino"
  end
  return base .. PATHSEP .. "arduino-cli"
end


---Path of the managed executable (whether or not it exists).
function managed.path()
  return managed.dir() .. PATHSEP .. cli.EXE_NAME
end


-- Runs a command, collecting stdout; must be called from a thread.
local function run(command)
  local ok, proc = pcall(process.start, command, { stdin = process.REDIRECT_DISCARD, stderr = process.REDIRECT_STDOUT })
  if not ok then return nil, tostring(proc) end
  handle.proc = proc
  local out = {}
  while true do
    if handle.cancelled then proc:kill() return nil, "cancelled" end
    local running = proc:running()
    local chunk = proc:read_stdout(65536)
    if chunk and #chunk > 0 then
      table.insert(out, chunk)
    elseif not chunk or not running then
      break
    else
      coroutine.yield(0.05)
    end
  end
  local output = table.concat(out)
  if proc:returncode() ~= 0 then
    return nil, output:gsub("%s+$", "") ~= "" and output:gsub("%s+$", "") or ("exit code " .. tostring(proc:returncode()))
  end
  return output
end


-- Archive suffix for this computer, e.g. "Linux_64bit.tar.gz".
local function asset_suffix()
  local machine
  if PLATFORM == "Windows" then
    machine = (os.getenv("PROCESSOR_ARCHITECTURE") or ""):lower()
    return (machine:find("64") and "Windows_64bit" or "Windows_32bit") .. ".zip"
  end
  machine = (run({ "uname", "-m" }) or ""):match("%S+") or ""
  if PLATFORM == "Mac OS X" then
    return (machine == "arm64" and "macOS_ARM64" or "macOS_64bit") .. ".tar.gz"
  end
  local names = { x86_64 = "Linux_64bit", amd64 = "Linux_64bit", aarch64 = "Linux_ARM64", arm64 = "Linux_ARM64",
    armv7l = "Linux_ARMv7", armv6l = "Linux_ARMv6", i686 = "Linux_32bit", i386 = "Linux_32bit" }
  local name = names[machine]
  return name and (name .. ".tar.gz"), machine
end


---Latest stable arduino-cli version, e.g. "1.5.1". Must be called from a thread.
function managed.latest_version()
  -- the page redirects to .../releases/tag/v1.5.1
  local headers, err = run({ "curl", "-sSI", "--max-time", "30", managed.LATEST_URL })
  if not headers then return nil, err end
  local version = headers:match("[Ll]ocation:%s*%S-/tag/v([%w%.%-]+)")
  if not version then return nil, "could not find the latest version at " .. managed.LATEST_URL end
  return version
end


local function sha256(path)
  local output
  if PLATFORM == "Windows" then
    output = run({ "certutil", "-hashfile", path, "SHA256" })
    return output and output:match("\n(%x+)%s*\n")
  elseif system.get_file_info("/usr/bin/sha256sum") or system.get_file_info("/bin/sha256sum") then
    output = run({ "sha256sum", path })
  else
    output = run({ "shasum", "-a", "256", path })
  end
  return output and output:match("^(%x+)")
end


local function set_status(status)
  managed.status = status
  core.redraw = true
end


local function fail(message, details)
  set_status({ state = "failed", error = message, details = details })
  core.warn("Could not download arduino-cli: %s%s", message, details and (" (" .. details .. ")") or "")
end


-- The download itself; must be called from a thread.
local function install()
  if not (system.get_file_info("/usr/bin/curl") or system.get_file_info("/bin/curl") or PLATFORM == "Windows") then
    return fail("curl is not installed. Install curl, or download arduino-cli yourself and use Locate.")
  end
  set_status({ state = "checking" })
  local suffix, machine = asset_suffix()
  if not suffix then return fail("There is no arduino-cli download for this kind of computer (" .. tostring(machine) .. ").") end
  local version, err = managed.latest_version()
  if not version then return fail(err == "cancelled" and "Cancelled." or "Could not find the latest version.", err) end

  local name = "arduino-cli_" .. version .. "_" .. suffix
  local url = managed.DOWNLOAD_BASE .. "/" .. name
  local dir = managed.dir()
  local tmp = dir .. PATHSEP .. "download"
  if not system.get_file_info(tmp) then common.mkdirp(tmp) end
  local archive = tmp .. PATHSEP .. name
  os.remove(archive)

  -- size, for the progress bar
  local headers = run({ "curl", "-sSIL", "--max-time", "30", url }) or ""
  local total
  for length in headers:gmatch("[Cc]ontent%-[Ll]ength:%s*(%d+)") do total = tonumber(length) end
  set_status({ state = "downloading", version = version, done = 0, total = total })

  -- download while watching the file grow
  local finished, download_err
  core.add_thread(function()
    local ok, e = run({ "curl", "-sSL", "--fail", "--max-time", "1800", "-o", archive, url })
    finished, download_err = true, not ok and e or nil
  end)
  while not finished do
    local info = system.get_file_info(archive)
    if info then managed.status.done = info.size core.redraw = true end
    coroutine.yield(0.1)
  end
  if handle.cancelled then os.remove(archive) return set_status({ state = "idle" }) end
  if download_err then return fail("The download failed.", download_err) end

  -- verify against the checksums published with the release
  set_status({ state = "verifying", version = version })
  local checksums, sums_err = run({ "curl", "-sSL", "--fail", "--max-time", "60",
    managed.RELEASE_BASE .. "/v" .. version .. "/" .. version .. "-checksums.txt" })
  if not checksums then return fail("Could not download the checksums to verify the download.", sums_err) end
  local expected = checksums:match("(%x+)%s+" .. name:gsub("%p", "%%%0"))
  local actual = sha256(archive)
  if not expected or not actual or expected:lower() ~= actual:lower() then
    os.remove(archive)
    return fail("The downloaded file did not match its published checksum, so it was not used.",
      "expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end

  -- unpack next to the old copy, then swap
  set_status({ state = "installing", version = version })
  local unpack = tmp .. PATHSEP .. "unpacked"
  run({ "rm", "-rf", unpack })
  common.mkdirp(unpack)
  local _, tar_err = run({ "tar", "-xf", archive, "-C", unpack })
  local exe = unpack .. PATHSEP .. cli.EXE_NAME
  if not system.get_file_info(exe) then return fail("Could not unpack the download.", tar_err) end
  os.remove(managed.path())
  local moved, move_err = os.rename(exe, managed.path())
  if not moved then return fail("Could not install the downloaded file.", move_err) end
  -- arduino-cli is GPLv3: keep its license next to it
  os.remove(dir .. PATHSEP .. "LICENSE.txt")
  os.rename(unpack .. PATHSEP .. "LICENSE.txt", dir .. PATHSEP .. "LICENSE.txt")
  if PLATFORM ~= "Windows" then run({ "chmod", "+x", managed.path() }) end
  run({ "rm", "-rf", tmp })

  set_status({ state = "idle" })
  core.log("Downloaded arduino-cli %s to %s", version, managed.path())
  cli.set_path(managed.path(), true)
end


---Downloads the latest arduino-cli and starts using it.
function managed.download()
  local s = managed.status.state
  if s ~= "idle" and s ~= "failed" then return end
  handle = {}
  core.add_thread(function()
    local ok, err = pcall(install)
    if not ok then fail("Unexpected error.", tostring(err)) end
  end)
end


---Stops a running download.
function managed.cancel()
  if handle and managed.status.state ~= "idle" and managed.status.state ~= "failed" then
    handle.cancelled = true
    if handle.proc then pcall(handle.proc.kill, handle.proc) end
    set_status({ state = "idle" })
    core.log("Cancelled downloading arduino-cli")
  end
end


---Whether a download is running.
function managed.busy()
  local s = managed.status.state
  return s ~= "idle" and s ~= "failed"
end


return managed
