-- How much installing a platform downloads and how much disk space it needs,
-- estimated from the board index files that arduino-cli keeps (it has no
-- command for this). A platform needs its own archive plus the archives of
-- its tools (compilers, upload tools) for this computer.
local cli = require "plugins.arduino.cli"
local json = require "plugins.arduino.json"

local install_size = {}

-- Unpacked files take about this many times the size of their archives
-- (measured: ESP32 about 3.5x, AVR about 5x). arduino-cli also keeps the
-- archives it downloaded (in staging/), so they count as well.
install_size.UNPACKED_FACTOR = 4


---Output of a short command, or nil. Must be called from a thread.
local function command_output(command)
  local ok, proc = pcall(process.start, command, { stdin = process.REDIRECT_DISCARD })
  if not ok or not proc then return nil end
  local parts = {}
  while true do
    local chunk = proc:read_stdout(4096)
    if chunk and #chunk > 0 then
      table.insert(parts, chunk)
    elseif not proc:running() then
      break
    else
      coroutine.yield(0.02)
    end
  end
  return table.concat(parts)
end


local host_patterns_cache
---Lua patterns of the index "host" names of tools that run on this computer,
---best first; they follow the matching rules of arduino-cli.
---Must be called from a thread.
---@return string[]
function install_size.host_patterns()
  if host_patterns_cache then return host_patterns_cache end
  local patterns
  if PLATFORM == "Windows" then
    local machine = (os.getenv("PROCESSOR_ARCHITECTURE") or ""):lower()
    patterns = machine:find("64") and { "^x86_64%-mingw32$", "^i%d86%-mingw32$", "^i686%-cygwin$" }
      or { "^i%d86%-mingw32$", "^i686%-cygwin$" }
  else
    local machine = (command_output({ "uname", "-m" }) or ""):match("%S+") or ""
    if PLATFORM == "Mac OS X" then
      -- Apple silicon also runs Intel tools
      patterns = machine == "arm64" and { "^arm64%-apple%-darwin", "^x86_64%-apple%-darwin" }
        or { "^x86_64%-apple%-darwin", "^i%d86%-apple%-darwin" }
    elseif machine == "x86_64" or machine == "amd64" then
      patterns = { "^x86_64%-.*linux%-gnu$" }
    elseif machine == "aarch64" or machine == "arm64" then
      patterns = { "^aarch64%-linux%-gnu$", "^arm64%-linux%-gnu$" }
    elseif machine:find("^arm") then
      patterns = { "^arm.*%-linux%-gnueabihf$" }
    else
      patterns = { "^i%d86%-.*linux%-gnu$" }
    end
  end
  host_patterns_cache = patterns
  return patterns
end


-- decoded index files by path, kept while the file is unchanged
local index_cache = {}

local function load_index(path)
  local info = system.get_file_info(path)
  if not info then return nil end
  local cached = index_cache[path]
  if cached and cached.modified == info.modified and cached.size == info.size then return cached.index end
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local text = fp:read("a")
  fp:close()
  local ok, index = pcall(json.decode, text)
  if not ok or type(index) ~= "table" then return nil end
  index_cache[path] = { modified = info.modified, size = info.size, index = index }
  return index
end


local function exists(path)
  return system.get_file_info(path) ~= nil
end


---Estimates what installing a platform version downloads and needs on disk.
---Parts already installed, or downloaded before, are not counted again.
---Must be called from a thread.
---@param id string Platform id, e.g. "esp32:esp32"
---@param version string e.g. "3.3.11"
---@return { download: integer, disk: integer }? size nil when the index has no sizes for it
function install_size.estimate(id, version)
  local vendor, arch = id:match("^([^:]+):(.+)$")
  local data_dir = cli.run_json({ "config", "get", "directories.data" })
  if not vendor or type(data_dir) ~= "string" or data_dir == "" then return nil end

  -- the Arduino index and those of the added board index URLs
  local packages = {}
  for _, name in ipairs(system.list_dir(data_dir) or {}) do
    if name:match("^package_.*index%.json$") then
      coroutine.yield()
      local index = load_index(data_dir .. PATHSEP .. name)
      for _, package in ipairs(index and type(index.packages) == "table" and index.packages or {}) do
        if type(package.name) == "string" and not packages[package.name] then packages[package.name] = package end
      end
    end
  end

  local release
  for _, platform in ipairs(packages[vendor] and packages[vendor].platforms or {}) do
    if platform.architecture == arch and platform.version == version then release = platform end
  end
  if not release or type(release.size) ~= "string" and type(release.size) ~= "number" then return nil end

  local staging = data_dir .. PATHSEP .. "staging" .. PATHSEP .. "packages" .. PATHSEP
  local download, disk = 0, 0
  local function add(size, archive, installed_dir)
    size = tonumber(size) or 0
    if exists(installed_dir) then return end
    if not (archive and exists(staging .. archive)) then
      download = download + size
      disk = disk + size
    end
    disk = disk + size * install_size.UNPACKED_FACTOR
  end

  add(release.size, release.archiveFileName,
    table.concat({ data_dir, "packages", vendor, "hardware", arch, version }, PATHSEP))

  local hosts = install_size.host_patterns()
  local seen = {}
  local dependencies = {}
  for _, key in ipairs({ "toolsDependencies", "discoveryDependencies", "monitorDependencies" }) do
    for _, dep in ipairs(type(release[key]) == "table" and release[key] or {}) do table.insert(dependencies, dep) end
  end
  for _, dep in ipairs(dependencies) do
    local packager, name, dep_version = dep.packager, dep.name, dep.version
    local tool_id = tostring(packager) .. ":" .. tostring(name) .. "@" .. tostring(dep_version or "")
    if not seen[tool_id] then
      seen[tool_id] = true
      local tool
      for _, candidate in ipairs(packages[packager] and packages[packager].tools or {}) do
        if candidate.name == name and (dep_version == nil or candidate.version == dep_version) then tool = candidate end
      end
      -- the build of the tool for this computer
      local system_entry
      for _, pattern in ipairs(hosts) do
        for _, entry in ipairs(tool and tool.systems or {}) do
          if not system_entry and type(entry.host) == "string" and entry.host:find(pattern) then system_entry = entry end
        end
      end
      if system_entry then
        add(system_entry.size, system_entry.archiveFileName,
          table.concat({ data_dir, "packages", packager, "tools", name, tool.version }, PATHSEP))
      end
    end
  end
  return { download = download, disk = disk }
end


---"712 MB", "3.4 GB", "850 KB" (1 MB = 1000 KB, as file managers show).
---@param bytes number
---@return string
function install_size.format(bytes)
  if bytes >= 1e9 then return string.format("%.1f GB", bytes / 1e9) end
  if bytes >= 1e6 then return string.format("%d MB", math.floor(bytes / 1e6 + 0.5)) end
  return string.format("%d KB", math.max(1, math.floor(bytes / 1e3 + 0.5)))
end


---A sentence about the size of an install, e.g.
---"Downloads about 712 MB and needs about 3.6 GB of disk space."
---@param size { download: integer, disk: integer }
---@return string
function install_size.describe(size)
  if size.disk == 0 then return "Everything it needs is already on this computer." end
  local disk = install_size.format(size.disk)
  if size.download == 0 then
    return "Its files were downloaded before; installing needs about " .. disk .. " of disk space."
  end
  return "Downloads about " .. install_size.format(size.download) .. " and needs about " .. disk .. " of disk space."
end


return install_size
