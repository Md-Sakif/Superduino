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
-- board options by fqbn (see `project.load_board_options`)
local options_cache = {}


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
  options_cache = {}
end


---A board setting, from the board's menus in boards.txt (e.g. Partition Scheme).
---@class arduino.board_option
---@field option string e.g. "PartitionScheme"
---@field label string e.g. "Partition Scheme"
---@field default string Value used when the setting is not changed
---@field values { value: string, label: string }[]


---Loads the settings a board offers besides its fqbn. Boards without any
---(e.g. Arduino UNO) return an empty list.
---Must be called from a thread (see `core.add_thread`).
---@param fqbn string
---@return arduino.board_option[]? options
---@return string? error
function project.load_board_options(fqbn)
  if options_cache[fqbn] then return options_cache[fqbn] end
  local result, err = cli.run_json({ "board", "details", "-b", fqbn })
  if not result then return nil, err end
  local options = {}
  for _, entry in ipairs(type(result.config_options) == "table" and result.config_options or {}) do
    if type(entry.option) == "string" and type(entry.values) == "table" and #entry.values > 0 then
      local option = { option = entry.option, label = entry.option_label or entry.option, values = {} }
      for _, value in ipairs(entry.values) do
        if type(value.value) == "string" then
          table.insert(option.values, { value = value.value, label = value.value_label or value.value })
          if value.selected then option.default = value.value end
        end
      end
      if #option.values > 0 then
        -- arduino-cli marks the default as selected; the first value is the default otherwise
        option.default = option.default or option.values[1].value
        table.insert(options, option)
      end
    end
  end
  options_cache[fqbn] = options
  return options
end


---The fqbn with the changed settings, e.g. "esp32:esp32:esp32:PSRAM=enabled".
---Settings left at their default are not included, so arduino-cli uses the default.
---@param fqbn string
---@param options arduino.board_option[]
---@param chosen table<string, string> Chosen value by option
---@return string
function project.fqbn_with_options(fqbn, options, chosen)
  local parts = {}
  for _, option in ipairs(options or {}) do
    local value = chosen[option.option]
    if value and value ~= option.default then table.insert(parts, option.option .. "=" .. value) end
  end
  return #parts > 0 and (fqbn .. ":" .. table.concat(parts, ",")) or fqbn
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


-------------------------------------------------------------------------------
-- Board indexes
-------------------------------------------------------------------------------

---The Boards Manager index that arduino-cli always uses.
project.DEFAULT_INDEX_URL = "https://downloads.arduino.cc/packages/package_index.json"

---Downloads the latest board indexes. Must be called from a thread.
---@return boolean updated
---@return string? error
function project.update_index()
  local _, err = cli.run_json({ "core", "update-index" }, { timeout = 120 })
  if err then return false, err end
  platforms_cache = nil
  return true
end


---Seconds since the board index was last downloaded, or nil when there is none.
---Must be called from a thread.
function project.index_age()
  local data_dir = cli.run_json({ "config", "get", "directories.data" })
  if type(data_dir) ~= "string" then return nil end
  local info = system.get_file_info(data_dir .. PATHSEP .. "package_index.json")
  -- modification times have fractions of a second; os.time() does not
  return info and math.max(0, os.time() - math.floor(info.modified)) or nil
end


---Extra board index URLs configured in arduino-cli. Must be called from a thread.
---@return string[]
function project.additional_urls()
  local urls = cli.run_json({ "config", "get", "board_manager.additional_urls" })
  return type(urls) == "table" and urls or {}
end


---Adds an extra board index URL and downloads it. Must be called from a thread.
---@return boolean added The URL is configured (even when downloading it failed).
---@return string? error Why the index could not be downloaded.
function project.add_index_url(url)
  local _, err = cli.run_json({ "config", "add", "board_manager.additional_urls", url })
  if err then return false, err end
  local updated, update_err = project.update_index()
  if not updated then
    -- report only problems with this URL; others may fail for unrelated reasons
    for line in update_err:gmatch("[^\n]+") do
      if line:find(url, 1, true) then return true, line end
    end
    return true, update_err
  end
  return true
end


---Removes an extra board index URL. Must be called from a thread.
function project.remove_index_url(url)
  local _, err = cli.run_json({ "config", "remove", "board_manager.additional_urls", url })
  platforms_cache = nil
  return err == nil, err
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
-- Templates
-------------------------------------------------------------------------------

---A starting point for a new sketch.
---@class arduino.template
---@field kind "empty"|"builtin"|"example"
---@field name string e.g. "Blink" or "SoftwareSerialExample"
---@field description string
---@field group string "Superduino starters" or the library name
---@field path? string Template file (builtin) or example folder (example).

---The default: arduino-cli's empty sketch.
project.EMPTY_TEMPLATE = { kind = "empty", name = "Empty sketch", group = "",
  description = "setup() and loop(), nothing else" }

local TEMPLATES_DIR = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "arduino" .. PATHSEP .. "templates"

---Starter sketches that ship with Superduino.
---@return arduino.template[]
function project.builtin_templates()
  local templates = {}
  for _, file in ipairs(system.list_dir(TEMPLATES_DIR) or {}) do
    local name = file:match("^(.+)%.ino$")
    if name then
      local path = TEMPLATES_DIR .. PATHSEP .. file
      local fp = io.open(path)
      local first = fp and fp:read("l") or ""
      if fp then fp:close() end
      local description = first:match("^//%s*[^:]+:%s*(.+)$") or ""
      table.insert(templates, { kind = "builtin", name = name, group = "Superduino starters",
        description = description, path = path })
    end
  end
  table.sort(templates, function(a, b) return a.name < b.name end)
  return templates
end


---Examples of the libraries available for a board (from `arduino-cli lib examples`).
---Must be called from a thread.
---@param fqbn string
---@return arduino.template[]? templates
---@return string? error
function project.load_examples(fqbn)
  local result, err = cli.run_json({ "lib", "examples", "--fqbn", fqbn })
  if not result then return nil, err end
  local templates = {}
  for _, entry in ipairs(result.examples or {}) do
    local library = entry.library or {}
    for _, dir in ipairs(entry.examples or {}) do
      table.insert(templates, { kind = "example", name = common.basename(dir), group = library.name or "?",
        description = "example of the " .. (library.name or "?") .. " library", path = dir })
    end
  end
  table.sort(templates, function(a, b)
    if a.group ~= b.group then return a.group:lower() < b.group:lower() end
    return a.name:lower() < b.name:lower()
  end)
  return templates
end


local function copy_file(from, to)
  local src = io.open(from, "rb")
  if not src then return false, "cannot read " .. from end
  local data = src:read("a")
  src:close()
  local dst = io.open(to, "wb")
  if not dst then return false, "cannot write " .. to end
  dst:write(data)
  dst:close()
  return true
end


local function copy_tree(from, to)
  for _, name in ipairs(system.list_dir(from) or {}) do
    local src, dst = from .. PATHSEP .. name, to .. PATHSEP .. name
    local info = system.get_file_info(src)
    if info and info.type == "dir" then
      if not system.get_file_info(dst) then
        local ok, err = common.mkdirp(dst)
        if not ok then return false, err end
      end
      local copied, copy_err = copy_tree(src, dst)
      if not copied then return false, copy_err end
    elseif info then
      local ok, err = copy_file(src, dst)
      if not ok then return false, err end
    end
  end
  return true
end


-- Puts a template's files into a freshly created sketch folder.
local function apply_template(path, template)
  local name = common.basename(path)
  local main = path .. PATHSEP .. name .. ".ino"
  if template.kind == "builtin" then
    return copy_file(template.path, main)
  elseif template.kind == "example" then
    local ok, err = copy_tree(template.path, path)
    if not ok then return false, err end
    -- the example's main file is named after its folder; the sketch's after the project
    local example_main = path .. PATHSEP .. common.basename(template.path) .. ".ino"
    if example_main ~= main and system.get_file_info(example_main) then
      os.remove(main)
      local renamed, rename_err = os.rename(example_main, main)
      if not renamed then return false, rename_err end
    end
  end
  return true
end


-------------------------------------------------------------------------------
-- Creating projects
-------------------------------------------------------------------------------

---Creates the sketch at `path` with a default build profile for `board`,
---optionally starting from a template. The parent folder must exist:
---arduino-cli would silently create missing folders.
---Must be called from a thread (see `core.add_thread`).
---@param path string
---@param board arduino.board
---@param template? arduino.template
---@param fqbn? string The board's fqbn with its chosen settings (see `project.fqbn_with_options`)
---@return boolean created
---@return string? error
function project.create(path, board, template, fqbn)
  fqbn = fqbn or board.fqbn
  local name = common.basename(path)
  local parent = common.dirname(path)
  local parent_info = parent and system.get_file_info(parent)
  if not parent_info or parent_info.type ~= "dir" then
    return false, "the folder " .. tostring(parent) .. " does not exist"
  end
  local _, err = cli.run_json({ "sketch", "new", path })
  if err then return false, err end
  if template and template.kind ~= "empty" then
    local ok, template_err = apply_template(path, template)
    if not ok then
      core.error("Created %s, but could not copy the template %s: %s", name, template.name, template_err)
    end
  end
  local profile = project.profile_name(board.fqbn)
  _, err = cli.run_json({ "profile", "create", "--profile", profile, "--fqbn", fqbn, "--set-default", path })
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
