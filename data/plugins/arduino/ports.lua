-- Connected boards' ports, followed live with `arduino-cli board list --watch`,
-- and the port chosen for each sketch.
local core = require "core"
local storage = require "core.storage"
local cli = require "plugins.arduino.cli"
local json = require "plugins.arduino.json"

local ports = {}

---@class arduino.port
---@field address string e.g. "/dev/ttyUSB0"
---@field label string e.g. "/dev/ttyUSB0"
---@field protocol string e.g. "serial"
---@field protocol_label string e.g. "Serial Port (USB)"
---@field boards { name: string, fqbn: string }[] Boards arduino-cli recognises on the port

---@type arduino.port[]
ports.list = {}
---"idle" (not started), "watching", or "stopped" (the watch ended; the list
---is then refreshed on demand)
ports.state = "idle"
ports.error = nil

local STORAGE_MODULE, STORAGE_KEY = "arduino", "ports"
local watcher -- { proc } of the running watch


local function to_port(entry)
  local port = type(entry) == "table" and type(entry.port) == "table" and entry.port
  if not port or type(port.address) ~= "string" then return nil end
  local boards = {}
  for _, board in ipairs(type(entry.matching_boards) == "table" and entry.matching_boards or {}) do
    if type(board.name) == "string" then table.insert(boards, { name = board.name, fqbn = board.fqbn }) end
  end
  return {
    address = port.address,
    label = type(port.label) == "string" and port.label or port.address,
    protocol = type(port.protocol) == "string" and port.protocol or "serial",
    protocol_label = type(port.protocol_label) == "string" and port.protocol_label or "",
    boards = boards,
  }
end


local function set_list(list)
  table.sort(list, function(a, b) return a.address < b.address end)
  ports.list = list
  core.redraw = true
end


---Applies one event of `board list --watch --json`.
---@param event table { eventType: "add"|"remove"|..., port, matching_boards }
function ports.apply_event(event)
  local kind = event.eventType or event.type
  local port = to_port(event)
  if not port or (kind ~= "add" and kind ~= "remove") then return end
  local list = {}
  for _, existing in ipairs(ports.list) do
    if existing.address ~= port.address or existing.protocol ~= port.protocol then table.insert(list, existing) end
  end
  if kind == "add" then table.insert(list, port) end
  set_list(list)
end


---Splits the complete JSON values at the start of a stream of concatenated
---values (as `board list --watch --json` prints them).
---@param buffer string
---@return string[] values
---@return string rest The incomplete end of the stream
function ports.split_json_stream(buffer)
  local values = {}
  local pos = 1
  while true do
    local start = buffer:find("[{%[]", pos)
    if not start then return values, "" end
    local depth, in_string, escaped, i = 0, false, false, start
    local done = nil
    while i <= #buffer do
      local c = buffer:sub(i, i)
      if in_string then
        if escaped then escaped = false
        elseif c == "\\" then escaped = true
        elseif c == '"' then in_string = false end
      elseif c == '"' then
        in_string = true
      elseif c == "{" or c == "[" then
        depth = depth + 1
      elseif c == "}" or c == "]" then
        depth = depth - 1
        if depth == 0 then done = i break end
      end
      i = i + 1
    end
    if not done then return values, buffer:sub(start) end
    table.insert(values, buffer:sub(start, done))
    pos = done + 1
  end
end


---Lists the ports once (`board list --json`). Must be called from a thread.
---@return boolean ok
---@return string? error
function ports.refresh()
  local result, err = cli.run_json({ "board", "list" })
  if not result then
    ports.error = err
    return false, err
  end
  local list = {}
  for _, entry in ipairs(type(result.detected_ports) == "table" and result.detected_ports or {}) do
    local port = to_port(entry)
    if port then table.insert(list, port) end
  end
  ports.error = nil
  set_list(list)
  return true
end


---Starts following the ports, if not already. Needs a working arduino-cli.
function ports.start()
  if watcher or cli.status ~= "ok" then return end
  local proc, err = cli.start({ "board", "list", "--watch", "--json" })
  if not proc then
    ports.state, ports.error = "stopped", err
    return
  end
  local this = { proc = proc }
  watcher = this
  ports.state = "watching"
  core.add_thread(function()
    local buffer = ""
    while true do
      if watcher ~= this then
        proc:kill()
        return
      end
      local out = proc:read_stdout(4096)
      if out and #out > 0 then
        local values
        values, buffer = ports.split_json_stream(buffer .. out)
        for _, text in ipairs(values) do
          local ok, event = pcall(json.decode, text)
          if ok and type(event) == "table" then ports.apply_event(event) end
        end
      elseif not proc:running() then
        break
      else
        coroutine.yield(0.1)
      end
    end
    -- the watch ended (e.g. an old arduino-cli): list on demand instead
    if watcher == this then
      watcher = nil
      ports.state = "stopped"
      core.warn("Stopped following connected boards (arduino-cli exited with %s)", tostring(proc:returncode()))
      ports.refresh()
    end
  end)
end


---Stops following the ports, e.g. when arduino-cli changes.
function ports.stop()
  watcher = nil
  ports.state = "idle"
end


---@param address string
---@return arduino.port?
function ports.find(address)
  for _, port in ipairs(ports.list) do
    if port.address == address then return port end
  end
end


---The port remembered for a sketch folder, whether connected or not.
---@param dir string
---@return string?
function ports.saved(dir)
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  return type(saved) == "table" and type(saved[dir]) == "string" and saved[dir] or nil
end


---Remembers the port of a sketch folder (nil forgets it).
---@param dir string
---@param address? string
function ports.save(dir, address)
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  saved = type(saved) == "table" and saved or {}
  saved[dir] = address
  storage.save(STORAGE_MODULE, STORAGE_KEY, saved)
  core.redraw = true
end


---The port to use for a sketch: the remembered one while it is connected,
---else one where arduino-cli recognises the sketch's board, else the only one
---(a board plugged in again often gets another name, e.g. ttyUSB1).
---@param dir string
---@param fqbn? string The sketch's board
---@return arduino.port? port
---@return boolean remembered Whether it is the remembered port
function ports.for_sketch(dir, fqbn)
  local saved = ports.saved(dir)
  local port = saved and ports.find(saved)
  if port then return port, true end
  local base = fqbn and fqbn:match("^([^:]+:[^:]+:[^:]+)")
  for _, candidate in ipairs(ports.list) do
    for _, board in ipairs(candidate.boards) do
      if base and board.fqbn == base then return candidate, false end
    end
  end
  if #ports.list == 1 then return ports.list[1], false end
  return nil, false
end


---"Arduino Uno" or "Serial Port (USB)": what is on a port, for showing next to its address.
---@param port arduino.port
function ports.describe(port)
  if port.boards[1] then return port.boards[1].name end
  return port.protocol_label ~= "" and port.protocol_label or port.protocol
end


return ports
