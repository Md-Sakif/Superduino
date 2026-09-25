-- Superduino testbench harness. tests/run.sh installs this as the user module
-- (init.lua) of a throwaway user directory, so it runs before any plugin loads.
--
-- A test case (tests/cases/*.lua) returns a table:
--   {
--     before = function(T) ... end,  -- optional; runs now, before plugins load
--     run = function(T) ... end,     -- runs in a thread once the editor is up
--   }
-- A case that restarts the editor (e.g. by opening a project) calls
-- T.expect_restart() first; `run` is then called again after the restart,
-- with T.phase increased by one.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

local T = {}
T.dir = assert(os.getenv("SUPERDUINO_TEST_DIR"), "SUPERDUINO_TEST_DIR not set")
T.fixtures = assert(os.getenv("SUPERDUINO_TEST_FIXTURES"), "SUPERDUINO_TEST_FIXTURES not set")
T.case = assert(os.getenv("SUPERDUINO_TEST_CASE"), "SUPERDUINO_TEST_CASE not set")
T.visible = os.getenv("SUPERDUINO_TEST_VISIBLE") == "1"
T.home = os.getenv("HOME")

local function read_file(path)
  local fp = io.open(path)
  if not fp then return nil end
  local text = fp:read("a")
  fp:close()
  return text
end
T.read_file = read_file

local function write_file(path, text, mode)
  local fp = assert(io.open(path, mode or "w"))
  fp:write(text)
  fp:close()
end
T.write_file = write_file

T.phase = tonumber(read_file(T.dir .. "/phase") or "1") or 1

local function result(line)
  write_file(T.dir .. "/results.txt", line .. "\n", "a")
end

---Records a passing or failing check.
function T.check(cond, message)
  result((cond and "ok " or "not ok ") .. message)
  return cond
end

function T.eq(actual, expected, message)
  local ok = actual == expected
  return T.check(ok, message .. (ok and "" or string.format(" (expected %q, got %q)", tostring(expected), tostring(actual))))
end

function T.match(text, pattern, message)
  local ok = type(text) == "string" and text:find(pattern) ~= nil
  return T.check(ok, message .. (ok and "" or string.format(" (%q does not match %q)", tostring(text), pattern)))
end

function T.log(fmt, ...)
  write_file(T.dir .. "/log.txt", string.format(fmt, ...) .. "\n", "a")
end

function T.wait(seconds)
  coroutine.yield(seconds or 0.1)
end

---Waits until `fn()` is truthy; records a failure named `what` on timeout.
function T.wait_until(fn, timeout, what)
  local deadline = system.get_time() + (timeout or 10)
  while system.get_time() < deadline do
    local ok, value = pcall(fn)
    if ok and value then return value end
    coroutine.yield(0.05)
  end
  T.check(false, "timed out waiting for " .. (what or "condition"))
  return nil
end

---Presses and releases a key through the key map, like a user would.
function T.key(stroke)
  keymap.on_key_pressed(stroke)
  keymap.on_key_released(stroke)
  coroutine.yield(0.02)
end

---Types text into the active view.
function T.type(text)
  core.active_view:on_text_input(text)
  coroutine.yield(0.02)
end

function T.command(name, ...)
  return command.perform(name, ...)
end

---Messages logged at warning or error level.
function T.problems()
  local list = {}
  for _, item in ipairs(core.log_items) do
    if item.level == "WARN" or item.level == "ERROR" then table.insert(list, item.text) end
  end
  return list
end

---Checks that nothing was logged at error level.
function T.no_errors(message)
  local errors = {}
  for _, item in ipairs(core.log_items) do
    if item.level == "ERROR" then table.insert(errors, item.text) end
  end
  return T.check(#errors == 0, (message or "no errors logged") .. (#errors > 0 and (": " .. table.concat(errors, " | ")) or ""))
end

-- Minimal JSON encoder for fake arduino-cli overrides.
local function encode(value)
  local t = type(value)
  if t == "table" then
    if #value > 0 or next(value) == nil and getmetatable(value) == T.ARRAY then
      local parts = {}
      for _, v in ipairs(value) do table.insert(parts, encode(v)) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(value) do table.insert(parts, encode(tostring(k)) .. ":" .. encode(v)) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return '"' .. value:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
  elseif value == nil then
    return "null"
  end
  return tostring(value)
end
T.ARRAY = {}
---Marks an empty table so it is encoded as a JSON array.
function T.array(t) return setmetatable(t or {}, T.ARRAY) end
T.json = encode

---Sets up the fake arduino-cli scenario (see tests/fixtures/bin/arduino-cli).
---Must be called in `before`, since the state is created on the first call.
function T.fake_cli(overrides)
  write_file(T.dir .. "/fake-cli-overrides.json", encode(overrides))
end

---Current state of the fake arduino-cli.
function T.fake_cli_calls()
  return read_file(T.dir .. "/fake-cli-calls.log") or ""
end

---Changes the fake arduino-cli state while the editor runs.
function T.fake_cli_set(key, value)
  -- re-encode the whole state file with Python to keep its structure intact
  local script = string.format(
    "import json,sys; p=%q; s=json.load(open(p)); s[%q]=json.loads(sys.argv[1]); json.dump(s, open(p,'w'))",
    T.dir .. "/fake-cli-state.json", key)
  local proc = process.start({ "python3", "-c", script, encode(value) })
  while proc:running() do coroutine.yield(0.02) end
end

---Uses the fake pkexec, with "ok", "cancel" or "fail" behaviour.
function T.fake_pkexec(mode)
  write_file(T.dir .. "/pkexec-mode", mode or "ok")
  local access = require "plugins.arduino.access"
  access.ADMIN_COMMAND = T.fixtures .. "/fake-pkexec"
end

function T.pkexec_calls()
  return read_file(T.dir .. "/pkexec-calls.log") or ""
end

---Opens the New Project wizard and waits until its lists are loaded.
function T.open_wizard()
  T.command("arduino:new-project")
  return T.wait_until(function()
    local view = core.active_view
    return tostring(view) == "NewProjectView" and not view.loading and view
  end, 15, "the New Project wizard to load")
end

---Label of the selected row in the wizard's current list.
function T.selected(view)
  local item = view:get_list()[view.selected]
  return item and item.label
end

---Creates a folder (and its parents).
function T.mkdir(path)
  local proc = process.start({ "mkdir", "-p", path })
  proc:wait(5)
end

---Saves a screenshot when running with --visible.
function T.shot(name)
  if not T.visible then return end
  local path = T.dir .. "/" .. name .. ".png"
  local cmd = "W=$(xdotool search --name 'Superduino$' | head -1); "
    .. "[ -n \"$W\" ] && timeout 5 import -window \"$W\" '" .. path .. "'"
  local proc = process.start({ "sh", "-c", cmd })
  while proc:running() do coroutine.yield(0.1) end
end

local restart_expected = false
function T.expect_restart()
  restart_expected = true
  write_file(T.dir .. "/phase", tostring(T.phase + 1))
end

function T.finish()
  write_file(T.dir .. "/done", "done\n")
  core.quit(true)
end

local case = assert(dofile(T.case))
if case.before and T.phase == 1 then case.before(T) end

core.add_thread(function()
  -- let startup work (plugins, arduino-cli check) settle
  coroutine.yield(0.5)
  local ok, err = xpcall(case.run, debug.traceback, T)
  if not ok then
    result("not ok test raised an error: " .. tostring(err):gsub("\n", " | "))
    T.finish()
  elseif not restart_expected then
    T.finish()
  end
end)

return T
