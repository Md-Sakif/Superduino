-- Building (compiling) and uploading a sketch with arduino-cli, one at a time.
-- The output is kept as parsed lines for the Output panel.
local core = require "core"
local common = require "core.common"
local cli = require "plugins.arduino.cli"

local build = {}

---@class arduino.build_line
---@field text string
---@field kind "command"|"error"|"warning"|"note"|"summary"|"hint"|"text"|"done"|"failed"
---@field file? string Absolute path, for compiler messages
---@field line? integer
---@field col? integer
---@field command? string Command to run when the line is clicked (hints)

---The current or last run:
---{ kind = "build"|"upload", dir, port?, state = "running"|"done"|"failed"|"cancelled",
---  lines = arduino.build_line[], errors, warnings, flash?, ram?, started, finished? }
build.last = nil
---Functions called with the run when it starts and when it ends.
build.on_start, build.on_finish = {}, {}

-- lines that are not worth showing
local function is_noise(text)
  return text:match("^%s*$") ~= nil
end


---Turns one line of output into a build line.
---@param text string
---@param dir string Sketch folder, for relative file names
---@return arduino.build_line
function build.parse_line(text, dir)
  text = text:gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
  local file, line, col, kind, message = text:match("^(.-):(%d+):(%d+): (%a[%a ]-): (.*)$")
  if not file then
    file, line, kind, message = text:match("^(.-):(%d+): (%a[%a ]-): (.*)$")
  end
  if file and (kind == "error" or kind == "fatal error" or kind == "warning" or kind == "note") then
    if not common.is_absolute_path(file) then file = dir .. PATHSEP .. file end
    return { text = text, kind = kind == "fatal error" and "error" or kind, file = file,
      line = tonumber(line), col = tonumber(col) or 1, message = message }
  end
  if text:match("^Sketch uses ") or text:match("^Global variables use ") then
    return { text = text, kind = "summary" }
  end
  if text:match("^Error during build") or text:match("^Failed uploading") or text:match("^Error during upload") then
    return { text = text, kind = "error" }
  end
  return { text = text, kind = "text" }
end


-- Hints for errors that have a known cause, added after the output.
local function hints(run)
  local all = {}
  for _, line in ipairs(run.lines) do table.insert(all, line.text) end
  local text = table.concat(all, "\n"):lower()
  local result = {}
  if run.kind == "upload" then
    if text:find("permission denied", 1, true) then
      table.insert(result, { kind = "hint", command = "arduino:allow-serial-port-access",
        text = "Your user may not be allowed to use serial ports. Click here to allow it (once, needs your password)." })
    elseif text:find("no such file or directory", 1, true) or text:find("can't open device", 1, true)
      or text:find("could not open port", 1, true) then
      table.insert(result, { kind = "hint",
        text = "The port could not be opened. Check that the board is plugged in and choose its port again." })
    elseif text:find("not in sync", 1, true) or text:find("timed out", 1, true)
      or text:find("failed to connect", 1, true) then
      table.insert(result, { kind = "hint",
        text = "The board did not answer. Check the board and port; some boards need a button pressed "
          .. "(e.g. BOOT on ESP32) while uploading starts." })
    end
  end
  if text:find("missing fqbn", 1, true) or text:find("no fqbn", 1, true) then
    table.insert(result, { kind = "hint", command = "arduino:board-settings",
      text = "The sketch has no board yet. Click here to choose one." })
  end
  return result
end


local function add_line(run, line)
  table.insert(run.lines, line)
  if line.kind == "error" and line.file then run.errors = run.errors + 1 end
  if line.kind == "warning" then run.warnings = run.warnings + 1 end
  if line.kind == "summary" then
    local percent = line.text:match("%((%d+)%%%)")
    if line.text:match("^Sketch uses") then run.flash = tonumber(percent) end
    if line.text:match("^Global variables") then run.ram = tonumber(percent) end
  end
  core.redraw = true
end


---Whether a build or upload is running.
function build.running()
  return build.last ~= nil and build.last.state == "running"
end


---Saves the open, changed files of a sketch folder before building.
local function save_sketch_docs(dir)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename and doc:is_dirty() and common.path_belongs_to(doc.abs_filename, dir) then
      local ok, err = pcall(doc.save, doc)
      if not ok then core.error("Could not save %s: %s", doc.abs_filename, tostring(err)) end
    end
  end
end


---Builds, or builds and uploads, a sketch.
---@param kind "build"|"upload"
---@param dir string Sketch folder
---@param port? string Port address, for uploading
---@return table? run
---@return string? error
function build.start(kind, dir, port)
  if build.running() then return nil, "a build is already running" end
  if kind == "upload" and not port then return nil, "no port chosen" end
  save_sketch_docs(dir)
  local args = { "compile", "--no-color", dir }
  if kind == "upload" then
    table.insert(args, "--upload")
    table.insert(args, "-p")
    table.insert(args, port)
  end
  local run = { kind = kind, dir = dir, port = port, state = "running", lines = {}, errors = 0, warnings = 0,
    started = system.get_time() }
  build.last = run
  add_line(run, { kind = "command", text = "arduino-cli " .. table.concat(args, " ") })
  local proc, err = cli.start(args)
  if not proc then
    run.state, run.finished = "failed", system.get_time()
    add_line(run, { kind = "failed", text = "Could not start arduino-cli: " .. tostring(err) })
    for _, fn in ipairs(build.on_finish) do fn(run) end
    return run
  end
  run.proc = proc
  for _, fn in ipairs(build.on_start) do fn(run) end

  core.add_thread(function()
    local buffers = { out = "", err = "" }
    local function flush(name, final)
      while true do
        local s, e = buffers[name]:find("\r?\n")
        if not s then break end
        local text = buffers[name]:sub(1, s - 1)
        buffers[name] = buffers[name]:sub(e + 1)
        -- progress bars rewrite their line with \r: keep the last state
        text = text:match("([^\r]*)$")
        if not is_noise(text) then add_line(run, build.parse_line(text, dir)) end
      end
      if final and not is_noise(buffers[name]) then
        add_line(run, build.parse_line(buffers[name]:match("([^\r]*)$"), dir))
        buffers[name] = ""
      end
    end
    while true do
      local out = proc:read_stdout(4096)
      local err_out = proc:read_stderr(4096)
      local got = false
      if out and #out > 0 then buffers.out = buffers.out .. out; flush("out"); got = true end
      if err_out and #err_out > 0 then buffers.err = buffers.err .. err_out; flush("err"); got = true end
      if not got then
        if not proc:running() then break end
        coroutine.yield(0.05)
      end
    end
    flush("out", true)
    flush("err", true)
    run.finished = system.get_time()
    local code = proc:returncode()
    if run.state == "cancelled" then
      add_line(run, { kind = "failed", text = (kind == "upload" and "Upload" or "Build") .. " cancelled." })
    elseif code == 0 then
      run.state = "done"
      add_line(run, { kind = "done", text = string.format("%s in %.1f s.",
        kind == "upload" and "Uploaded to " .. port or "Build done", run.finished - run.started) })
    else
      run.state = "failed"
      for _, hint in ipairs(hints(run)) do add_line(run, hint) end
      add_line(run, { kind = "failed", text = string.format("%s failed (exit code %s).",
        kind == "upload" and "Upload" or "Build", tostring(code)) })
    end
    run.proc = nil
    for _, fn in ipairs(build.on_finish) do fn(run) end
    core.redraw = true
  end)
  return run
end


---Stops the running build or upload.
function build.cancel()
  local run = build.last
  if not run or run.state ~= "running" or not run.proc then return end
  run.state = "cancelled"
  run.proc:terminate()
  -- arduino-cli normally stops on SIGTERM; make sure it does
  local proc = run.proc
  core.add_thread(function()
    local deadline = system.get_time() + 3
    while proc:running() and system.get_time() < deadline do coroutine.yield(0.1) end
    if proc:running() then proc:kill() end
  end)
end


return build
