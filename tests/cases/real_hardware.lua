--! FAKE_CLI_ON_PATH=0
--! TIMEOUT=600
-- Uses a real board, the real arduino-cli and its installed Arduino AVR
-- Boards, with an Arduino Nano (or clone) plugged in:
--
--   SUPERDUINO_REAL_TESTS=1 SUPERDUINO_HW_PORT=/dev/ttyUSB0 \
--   SUPERDUINO_HW_CLI=$HOME/path/to/arduino-cli SUPERDUINO_HW_DATA=$HOME/.arduino15 \
--   tests/run.sh --visible real_hardware
--
-- The test's home uses SUPERDUINO_HW_DATA (arduino-cli's data folder, with
-- its config, indexes and platforms) so nothing is downloaded. It overwrites
-- the program on the board. Unplugging is not tested (it needs a person).
--
-- New Project with the board's settings, the Board and Build sections with
-- the real port watch, a build error from the real compiler, an upload that
-- needs the old bootloader setting (most Nano clones) fixed through its hint
-- and Board Settings, then the Serial Monitor and Plotter on the board.
local SKETCH = [[
// Superduino hardware test: greets, prints numbers for the plotter, and
// echoes what it receives with \r and \n made visible.
unsigned long count = 0;
unsigned long last_print = 0, last_rx = 0;
String rx;

void setup() {
  Serial.begin(115200);
  Serial.println("Superduino test ready");
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') rx += "\\r";
    else if (c == '\n') rx += "\\n";
    else rx += c;
    last_rx = millis();
  }
  if (rx.length() > 0 && millis() - last_rx > 50) {
    Serial.print("got \"");
    Serial.print(rx);
    Serial.println("\"");
    rx = "";
  }
  if (millis() - last_print >= 200) {
    last_print = millis();
    count++;
    Serial.print("count:");
    Serial.print(count);
    Serial.print(" wave:");
    Serial.println((int)(100 * sin(count / 5.0)));
  }
}
]]

local REAL = os.getenv("SUPERDUINO_REAL_TESTS") == "1"
local PORT, CLI, DATA = os.getenv("SUPERDUINO_HW_PORT"), os.getenv("SUPERDUINO_HW_CLI"), os.getenv("SUPERDUINO_HW_DATA")
local READY = REAL and PORT and PORT ~= "" and CLI and CLI ~= "" and DATA and DATA ~= ""

return {
  before = function(T)
    if not READY then return end
    -- the real arduino-cli with the real data folder
    local proc = process.start({ "ln", "-s", DATA, T.home .. "/.arduino15" })
    proc:wait(5)
    require("core.storage").save("arduino", "cli", { path = CLI })
  end,
  run = function(T)
    if not READY then
      T.check(true, "skipped: set SUPERDUINO_REAL_TESTS=1 and SUPERDUINO_HW_PORT, _CLI, _DATA to run")
      return
    end
    local core = require "core"
    local cli = require "plugins.arduino.cli"
    local dir = T.home .. "/Arduino/HwTest"
    local ino = dir .. "/HwTest.ino"

    if T.phase == 1 then
      T.wait_until(function() return cli.status == "ok" end, 30, "the real arduino-cli")
      T.log("arduino-cli %s at %s", tostring(cli.version), tostring(cli.path))
      -- New Project: Arduino, AVR Boards, Nano, its settings, a name
      local v = T.open_wizard()
      T.eq(T.selected(v), "Arduino", "Arduino is the first vendor")
      T.key("return")
      T.match(T.selected(v) or "", "AVR", "the installed AVR family comes first")
      T.key("return")
      T.type("arduino nano")
      T.eq(T.selected(v), "Arduino Nano", "the Nano is found")
      T.key("return")
      T.eq(v.step, 4, "the Nano has settings")
      T.wait_until(function() return v.board_options and not v.board_options.loading end, 30, "its real settings")
      T.eq(T.selected(v), "Processor", "Processor is a setting")
      T.eq(v:get_list()[1].detail, "ATmega328P", "ATmega328P by default")
      T.shot("hw-wizard-options")
      T.key("return")
      T.name_step(v)
      -- a fresh home has no sketchbook folder yet: create it as a user would
      local create_folder = v.current_layout.create_folder
      if create_folder then
        v:on_mouse_pressed("left", create_folder.x + 2, create_folder.y + 2, 1)
        T.check(v:location_exists(), "Create Folder makes the sketchbook folder")
      end
      T.type("HwTest")
      T.expect_restart()
      T.key("return")
      return
    end

    local build = require "plugins.arduino.build"
    local ports = require "plugins.arduino.ports"
    local monitor = require "plugins.arduino.serial_monitor"
    local plot = require "plugins.arduino.serial_plot"
    local BuildPanel = require "plugins.arduino.build_panel"
    local BoardPanel = require "plugins.arduino.board_panel"
    local OutputView = require "plugins.arduino.output_view"
    local SerialView = require "plugins.arduino.serial_view"
    local PlotView = require "plugins.arduino.serial_plot_view"
    local PanelBar = require "plugins.arduino.panel_bar"
    T.wait_until(function() return cli.status == "ok" end, 30, "the real arduino-cli")

    -- the project the wizard made
    local yaml = T.read_file(dir .. "/sketch.yaml") or ""
    T.match(yaml, "fqbn: arduino:avr:nano\n", "sketch.yaml has the Nano")
    T.match(yaml, "platform: arduino:avr %(%d+%.%d+%.%d+%)", "and the installed platform version")
    local rows = T.wait_until(function()
      local d = BoardPanel.describe()
      return d and d.options_known and d.rows
    end, 30, "the Board section")
    local values = {}
    for _, row in ipairs(rows or {}) do values[row.label] = row.value end
    T.eq(values.Board, "Arduino Nano", "the Board section shows the Nano")

    -- the port watch finds the board
    local port = T.wait_until(function() return BuildPanel.sketch().port end, 15, "the board's port")
    T.eq(port and port.address, PORT, "the plugged-in board's port is chosen")
    T.log("port: %s (%s)", tostring(port and port.address), port and ports.describe(port) or "")

    local function finished(what)
      return T.wait_until(function() return build.last and build.last.state ~= "running" end, 240, what)
    end
    local function status() return BuildPanel.view:status(BuildPanel.sketch()) end
    local function hint_of(run)
      for _, line in ipairs(run.lines) do if line.kind == "hint" then return line end end
    end

    -- a compile error from the real compiler opens at its line
    local broken = SKETCH:gsub("  count%+%+;", "  count++;\n  undefined_function(count);")
    local broken_line = select(2, broken:sub(1, broken:find("undefined_function", 1, true)):gsub("\n", "")) + 1
    T.write_file(ino, broken)
    T.key("ctrl+b")
    finished("the failing build")
    T.eq(build.last.state, "failed", "the build fails")
    local error_line
    for _, line in ipairs(build.last.lines) do
      if line.kind == "error" and line.file then error_line = error_line or line end
    end
    T.eq(error_line and error_line.file, ino, "the error names the sketch file")
    T.eq(error_line and error_line.line, broken_line, "at the line of the mistake")
    T.match(error_line and error_line.text or "", "undefined_function", "with the compiler's message")
    T.eq(status(), "Build failed: 1 error", "the Build section counts it")
    T.shot("hw-build-error")

    -- a good build, with the memory use
    T.write_file(ino, SKETCH)
    T.key("ctrl+b")
    finished("the build")
    T.eq(build.last.state, "done", "the build succeeds")
    T.match(select(3, status()) or "", "^Flash %d+%%  ·  RAM %d+%%$", "the memory use is shown")
    T.log("build: %s", tostring(select(3, status())))

    -- Upload; a clone Nano needs the old bootloader, which the hint offers
    T.key("ctrl+u")
    finished("the first upload")
    local hint
    if build.last.state == "failed" then
      hint = hint_of(build.last)
      T.eq(hint and hint.command, "arduino:board-settings", "the failed upload offers Board Settings")
      T.shot("hw-upload-hint")
      OutputView.view:open_line(hint)
      local v = T.wait_until(function()
        local view = core.active_view
        return tostring(view) == "NewProjectView" and view.board_options and not view.board_options.loading and view
      end, 30, "Board Settings")
      T.eq(v and v.step, 4, "on the settings step")
      T.eq(T.selected(v), "Processor", "at the Processor setting")
      T.key("right")
      T.eq(v:get_list()[1].detail, "ATmega328P (Old Bootloader)", "the old bootloader is next")
      T.shot("hw-board-settings")
      T.key("return")
      T.wait_until(function() return BuildPanel.sketch().fqbn == "arduino:avr:nano:cpu=atmega328old" end, 15,
        "the changed board")
      T.match(T.read_file(dir .. "/sketch.yaml") or "", "fqbn: arduino:avr:nano:cpu=atmega328old\n",
        "sketch.yaml has the setting")
      T.key("ctrl+u")
      finished("the upload with the old bootloader")
    else
      T.log("the board took the new bootloader setting")
    end
    T.eq(build.last.state, "done", "the upload succeeds")
    T.eq(status(), "Uploaded to " .. PORT, "the Build section says where")
    T.shot("hw-uploaded")

    -- the Serial Monitor, at the sketch's Serial.begin() rate
    local bar = PanelBar.view
    local function click_tab(name)
      for _, t in ipairs(bar.tabs) do
        if t.tab.text == name then bar:on_mouse_pressed("left", t.x + 2, t.y + 2, 1) end
      end
    end
    local function count_lines(text)
      local n = 0
      for _, line in ipairs(monitor.lines) do if line.text:find(text, 1, true) then n = n + 1 end end
      return n
    end
    local function has_line(text) return count_lines(text) > 0 end
    click_tab("Serial Monitor")
    local view = SerialView.view
    T.wait_until(function() return has_line("Superduino test ready") end, 15, "the board's greeting")
    T.eq(monitor.session and monitor.session.baud, 115200, "connected at the sketch's 115200 baud")
    T.wait_until(function() return count_lines("count:") >= 5 end, 10, "the board's numbers")
    T.shot("hw-serial-monitor")
    -- sending, with the line endings
    T.type("led on")
    T.key("return")
    T.wait_until(function() return has_line('got "led on\\n"') end, 10, "the echo with Newline")
    monitor.set_line_ending("crlf")
    T.type("x")
    T.key("return")
    T.wait_until(function() return has_line('got "x\\r\\n"') end, 10, "the echo with Both NL & CR")
    monitor.set_line_ending("none")
    T.type("raw")
    T.key("return")
    T.wait_until(function() return has_line('got "raw"') end, 10, "the echo with No Line Ending")
    monitor.set_line_ending("lf")
    T.shot("hw-serial-sent")

    -- the plotter on the same connection
    click_tab("Serial Plotter")
    T.check(PlotView.is_open() and not view.visible, "the Serial Plotter replaces the monitor")
    T.wait_until(function() return #plot.series >= 2 and plot.count >= 15 end, 15, "plotted samples")
    local names = {}
    for _, s in ipairs(plot.series) do table.insert(names, s.name) end
    T.eq(table.concat(names, ","), "count,wave", "count and wave are plotted (greeting and echoes are not)")
    T.shot("hw-serial-plotter")

    -- an upload pauses the connection, then it comes back on the restarted board
    local greetings = count_lines("Superduino test ready")
    core.set_active_view(core.root_view:get_primary_node().active_view)
    T.key("ctrl+u")
    T.eq(monitor.state(), "paused", "uploading pauses the connection")
    finished("the upload while connected")
    T.eq(build.last.state, "done", "the upload succeeds (the port was freed)")
    T.wait_until(function() return monitor.state() == "connected" end, 15, "the connection again")
    T.check(PlotView.is_open(), "the plotter shows again")
    T.wait_until(function() return count_lines("Superduino test ready") > greetings end, 15,
      "the greeting of the restarted board")

    -- a wrong baud rate, then the right one again
    monitor.choose_baud(dir, 9600)
    SerialView.get():show()
    SerialView.connect()
    T.wait_until(function() return monitor.session and monitor.session.baud == 9600 and monitor.state() == "connected" end,
      15, "the connection at 9600")
    T.wait_until(function()
      for _, line in ipairs(monitor.lines) do
        if line.kind == "hint" and line.command == "arduino:serial-baud-rate" then return true end
      end
    end, 15, "the hint about unreadable text")
    T.shot("hw-serial-wrong-baud")
    monitor.choose_baud(dir, 115200)
    greetings = count_lines("Superduino test ready")
    SerialView.connect()
    T.wait_until(function() return count_lines("Superduino test ready") > greetings end, 15, "readable text again")
    click_tab("Serial Monitor")
    T.wait(0.5)
    T.shot("hw-serial-back")
    monitor.disconnect()
    T.eq(monitor.state(), "disconnected", "Disconnect frees the port")
    T.no_errors()
  end,
}
