-- The serial monitor: what a board prints over its serial port, and text sent
-- to it, through `arduino-cli monitor`. One connection at a time; it pauses
-- while an upload uses the port and connects again afterwards.
local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local cli = require "plugins.arduino.cli"
local build = require "plugins.arduino.build"
local ports = require "plugins.arduino.ports"

local monitor = {}

---Baud rates offered (those of arduino-cli's serial monitor).
monitor.BAUD_RATES = { 300, 600, 750, 1200, 2400, 4800, 9600, 19200, 31250, 38400, 57600, 74880, 115200,
  230400, 250000, 460800, 500000, 921600, 1000000, 2000000 }
monitor.DEFAULT_BAUD = 9600

---What is added after sent text.
monitor.LINE_ENDINGS = {
  { id = "none", label = "No Line Ending", text = "" },
  { id = "lf", label = "Newline", text = "\n" },
  { id = "cr", label = "Carriage Return", text = "\r" },
  { id = "crlf", label = "Both NL & CR", text = "\r\n" },
}

---Lines kept; older ones are dropped.
monitor.MAX_LINES = 10000

---@class arduino.serial_line
---@field text string
---@field kind "rx"|"info"|"error"|"hint"
---@field time number Seconds since the epoch, with milliseconds
---@field command? string Command to run when the line is clicked (hints)

---@type arduino.serial_line[]
monitor.lines = {}
---The received line still being written (no line break yet).
---@type arduino.serial_line?
monitor.partial = nil
---Lines dropped from the start so far (keeps line numbers stable for scrolling).
monitor.dropped = 0

---The connection: { port, baud, fqbn?, protocol?, state = "connecting"|"connected"|"closed"|"failed", proc }
monitor.session = nil
---The connection paused by an upload, to connect again after it: { port, baud, fqbn?, protocol? }
monitor.paused = nil
---After a board was unplugged: { port, baud, fqbn?, protocol? }, to connect again when it is back.
monitor.waiting = nil
---Functions called when the monitor pauses for an upload and when it resumes.
monitor.on_pause, monitor.on_resume = {}, {}

-- considered connected when arduino-cli is still running after this long
-- (with --quiet it prints nothing when the port opens)
local CONNECT_SETTLE = 1.0

local STORAGE_MODULE, STORAGE_KEY = "arduino", "serial"


-- wall-clock time with milliseconds: the monotonic clock, set to the wall clock once
local clock_offset = os.time() - system.get_time()
local function now()
  return clock_offset + system.get_time()
end


local function settings()
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  saved = type(saved) == "table" and saved or {}
  saved.bauds = type(saved.bauds) == "table" and saved.bauds or {}
  return saved
end


local function save_settings(saved)
  storage.save(STORAGE_MODULE, STORAGE_KEY, saved)
  core.redraw = true
end


-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

---The baud rate a sketch sets with Serial.begin(...), if any.
---@param dir string Sketch folder
---@return integer? baud
---@return string? file Name of the file it was found in
function monitor.detect_baud(dir)
  local files = system.list_dir(dir) or {}
  table.sort(files, function(a, b)
    -- the main .ino file first
    local main = common.basename(dir) .. ".ino"
    if (a == main) ~= (b == main) then return a == main end
    return a < b
  end)
  for _, name in ipairs(files) do
    if name:match("%.ino$") or name:match("%.cpp$") or name:match("%.h$") then
      local fp = io.open(dir .. PATHSEP .. name, "rb")
      local text = fp and fp:read(1024 * 1024)
      if fp then fp:close() end
      for line in (text or ""):gmatch("[^\n]+") do
        local code = line:gsub("//.*$", "")
        local baud = code:match("Serial%s*%.%s*begin%s*%(%s*(%d+)")
        if baud then return tonumber(baud), name end
      end
    end
  end
end


---The baud rate to use for a sketch: the one the user chose, unless the
---sketch's Serial.begin(...) changed since; else the sketch's; else 9600.
---@param dir string Sketch folder
---@return integer baud
---@return "chosen"|"sketch"|"default" source
---@return string? file The file with Serial.begin(...)
function monitor.baud_for(dir)
  local detected, file = monitor.detect_baud(dir)
  local chosen = settings().bauds[dir]
  if type(chosen) == "table" and tonumber(chosen.baud) and chosen.detected == detected then
    return tonumber(chosen.baud), "chosen", file
  end
  if detected then return detected, "sketch", file end
  return monitor.DEFAULT_BAUD, "default"
end


---Remembers the baud rate chosen for a sketch (together with what the sketch
---sets, so a later change of Serial.begin(...) wins).
function monitor.choose_baud(dir, baud)
  local saved = settings()
  saved.bauds[dir] = { baud = baud, detected = monitor.detect_baud(dir) }
  save_settings(saved)
end


---@return { id: string, label: string, text: string }
function monitor.line_ending()
  local id = settings().line_ending or "lf"
  for _, ending in ipairs(monitor.LINE_ENDINGS) do
    if ending.id == id then return ending end
  end
  return monitor.LINE_ENDINGS[2]
end


function monitor.set_line_ending(id)
  local saved = settings()
  saved.line_ending = id
  save_settings(saved)
end


function monitor.timestamps()
  return settings().timestamps == true
end


function monitor.set_timestamps(on)
  local saved = settings()
  saved.timestamps = on and true or nil
  save_settings(saved)
end


-------------------------------------------------------------------------------
-- Lines
-------------------------------------------------------------------------------

local function trim()
  local extra = #monitor.lines - monitor.MAX_LINES
  if extra > 0 then
    table.move(monitor.lines, extra + 1, #monitor.lines, 1)
    for i = #monitor.lines, #monitor.lines - extra + 1, -1 do monitor.lines[i] = nil end
    monitor.dropped = monitor.dropped + extra
  end
end


---Adds a line of Superduino's own (connected, disconnected, errors), ending a
---received line still being written.
---@param kind "info"|"error"|"hint"
---@param text string
---@param command? string
function monitor.add_note(kind, text, command)
  if monitor.partial then
    table.insert(monitor.lines, monitor.partial)
    monitor.partial = nil
  end
  table.insert(monitor.lines, { text = text, kind = kind, time = now(), command = command })
  trim()
  core.redraw = true
end


-- shown as text: tabs as spaces, other control characters dropped
local function printable(text)
  return (text:gsub("\t", "    "):gsub("[%z\1-\8\11-\31\127]", ""))
end


---Adds received bytes: complete lines, and the start of the next one.
---@param data string
function monitor.receive(data)
  local partial = monitor.partial
  local text = (partial and partial.raw or "") .. data
  local time = partial and partial.time or now()
  while true do
    local s = text:find("\n", 1, true)
    if not s then break end
    table.insert(monitor.lines, { text = printable(text:sub(1, s - 1)), kind = "rx", time = time })
    text = text:sub(s + 1)
    time = now()
  end
  trim()
  monitor.partial = text ~= "" and { text = printable(text), raw = text, kind = "rx", time = time } or nil
  core.redraw = true
end


---Removes all lines.
function monitor.clear()
  monitor.lines, monitor.partial = {}, nil
  monitor.dropped = 0
  core.redraw = true
end


---All lines as text, e.g. for the clipboard.
---@param timestamps? boolean
function monitor.text(timestamps)
  local out = {}
  local function add(line)
    table.insert(out, (timestamps and (monitor.format_time(line.time) .. "  ") or "") .. line.text)
  end
  for _, line in ipairs(monitor.lines) do add(line) end
  if monitor.partial then add(monitor.partial) end
  return table.concat(out, "\n")
end


---"14:03:07.250"
function monitor.format_time(time)
  return os.date("%H:%M:%S", math.floor(time)) .. string.format(".%03d", math.floor((time % 1) * 1000))
end


-------------------------------------------------------------------------------
-- The connection
-------------------------------------------------------------------------------

---"disconnected", "connecting", "connected", "paused" (for an upload) or
---"waiting" (for an unplugged board to come back).
function monitor.state()
  local session = monitor.session
  if session and (session.state == "connecting" or session.state == "connected") then return session.state end
  if monitor.paused then return "paused" end
  if monitor.waiting then return "waiting" end
  return "disconnected"
end


---Whether the monitor uses (or is about to use) a port.
function monitor.active()
  return monitor.state() ~= "disconnected"
end


-- Hints for errors that have a known cause.
local function hint_for(text)
  text = text:lower()
  if text:find("permission denied", 1, true) then
    return "Your user may not be allowed to use serial ports. Click here to allow it (once, needs your password).",
      "arduino:allow-serial-port-access"
  elseif text:find("busy", 1, true) then
    return "Another program is using the port (another serial monitor, or an upload). Close it and connect again."
  elseif text:find("no such file", 1, true) or text:find("not found", 1, true) then
    return "The port is gone. Check that the board is plugged in and choose its port again."
  end
end


---Connects to a port; a connection to another port or at another baud rate is closed first.
---@param target { port: string, baud: integer, fqbn?: string, protocol?: string }
---@return boolean ok
function monitor.connect(target)
  if cli.status ~= "ok" then
    monitor.add_note("error", "arduino-cli is not available; see the Arduino CLI section on the welcome screen.")
    return false
  end
  monitor.disconnect(true)
  monitor.waiting, monitor.paused = nil, nil
  local args = { "monitor", "-p", target.port, "--config", "baudrate=" .. target.baud, "--quiet", "--no-color" }
  if target.protocol then
    table.insert(args, "-l")
    table.insert(args, target.protocol)
  end
  if target.fqbn then
    -- the board's own port settings (some boards reset when DTR/RTS are on)
    table.insert(args, "-b")
    table.insert(args, target.fqbn)
  end
  monitor.add_note("info", string.format("Connecting to %s at %d baud...", target.port, target.baud))
  local proc, err = cli.start(args, { stdin = true })
  if not proc then
    monitor.add_note("error", "Could not start arduino-cli: " .. tostring(err))
    return false
  end
  local session = { port = target.port, baud = target.baud, fqbn = target.fqbn, protocol = target.protocol,
    state = "connecting", proc = proc, started = system.get_time() }
  monitor.session = session

  core.add_thread(function()
    local errors = ""
    while true do
      local out = proc:read_stdout(4096)
      local err_out = proc:read_stderr(4096)
      local got = false
      if out and #out > 0 then
        if monitor.session == session then
          if session.state == "connecting" then
            session.state = "connected"
            monitor.add_note("info", string.format("Connected to %s at %d baud.", session.port, session.baud))
          end
          monitor.receive(out)
        end
        got = true
      end
      if err_out and #err_out > 0 then errors = errors .. err_out; got = true end
      if not got then
        if not proc:running() then break end
        if session.state == "connecting" and system.get_time() - session.started > CONNECT_SETTLE
          and monitor.session == session then
          session.state = "connected"
          monitor.add_note("info", string.format("Connected to %s at %d baud.", session.port, session.baud))
        end
        coroutine.yield(0.03)
      end
    end
    if monitor.session ~= session or session.state == "closed" then return end
    -- it ended by itself: the port could not be opened, or the board was unplugged
    monitor.session = nil
    local was_connected = session.state == "connected"
    session.state = "failed"
    local message = errors:gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
    if message == "" then message = "arduino-cli exited with " .. tostring(proc:returncode()) end
    monitor.add_note("error", (was_connected and "Disconnected: " or "Could not connect: ") .. message)
    local hint, command = hint_for(message)
    if hint then monitor.add_note("hint", hint, command) end
    if was_connected then
      -- connect again when the board is back
      monitor.waiting = { port = session.port, baud = session.baud, fqbn = session.fqbn, protocol = session.protocol,
        gone = ports.find(session.port) == nil, since = system.get_time() }
      monitor.add_note("info", "Will connect again when " .. session.port .. " is back.")
    end
  end)
  return true
end


---Closes the connection.
---@param quiet? boolean Do not add a "Disconnected" line
function monitor.disconnect(quiet)
  local waiting = monitor.waiting
  monitor.waiting = nil
  local session = monitor.session
  if not session then
    if waiting and not quiet then monitor.add_note("info", "Stopped waiting for " .. waiting.port .. ".") end
    return
  end
  monitor.session = nil
  session.state = "closed"
  local proc = session.proc
  proc:terminate()
  core.add_thread(function()
    local deadline = system.get_time() + 2
    while proc:running() and system.get_time() < deadline do coroutine.yield(0.05) end
    if proc:running() then proc:kill() end
  end)
  if not quiet then monitor.add_note("info", "Disconnected from " .. session.port .. ".") end
end


---Sends text with the chosen line ending.
---@param text string
---@return boolean ok
function monitor.send(text)
  local session = monitor.session
  if not session or (session.state ~= "connected" and session.state ~= "connecting") then return false end
  local data = text .. monitor.line_ending().text
  if data == "" then return true end
  core.add_thread(function()
    local ok, err = pcall(session.proc.stdin.write, session.proc.stdin, data)
    if not ok then monitor.add_note("error", "Could not send: " .. tostring(err)) end
  end)
  return true
end


-- connect again when an unplugged board comes back: once its port is listed
-- again, or after a while when it never left the list (the port list may miss
-- a quick replug, and some errors leave the port listed)
local RETRY_AFTER = 2
core.add_thread(function()
  while true do
    local waiting = monitor.waiting
    if waiting and not monitor.session then
      if not ports.find(waiting.port) then
        waiting.gone = true
      elseif waiting.gone or system.get_time() - waiting.since > RETRY_AFTER then
        monitor.connect(waiting)
      end
    end
    coroutine.yield(0.25)
  end
end)


-- an upload needs the port: pause, then connect again afterwards (to the
-- sketch's port, which some boards change while uploading)
table.insert(build.on_start, 1, function(run)
  if run.kind ~= "upload" then return end
  local session = monitor.session or monitor.waiting
  if not session then return end
  local paused = { port = session.port, baud = session.baud, fqbn = session.fqbn, protocol = session.protocol }
  -- (the upload starts with compiling, so the port is free long before it is needed)
  monitor.disconnect(true)
  monitor.paused = paused
  monitor.add_note("info", "Paused while uploading.")
  for _, fn in ipairs(monitor.on_pause) do fn(run) end
end)

table.insert(build.on_finish, function(run)
  local paused = monitor.paused
  if run.kind ~= "upload" or not paused then return end
  core.add_thread(function()
    -- give the board a moment to start again (and a new port to appear)
    coroutine.yield(0.5)
    if monitor.paused ~= paused then return end
    monitor.paused = nil
    local target = { port = run.port or paused.port, baud = paused.baud, fqbn = paused.fqbn, protocol = paused.protocol }
    if run.dir then
      local port = ports.for_sketch(run.dir, paused.fqbn)
      if port then target.port, target.protocol = port.address, port.protocol end
      target.baud = monitor.baud_for(run.dir)
    end
    monitor.connect(target)
    for _, fn in ipairs(monitor.on_resume) do fn(run) end
  end)
end)


-- a changed arduino-cli: close the connection made with the old one
table.insert(cli.on_checked, function()
  if monitor.session and cli.status ~= "ok" then monitor.disconnect() end
end)


return monitor
