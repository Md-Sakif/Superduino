-- The Serial Monitor tab connects to the sketch's port at the sketch's baud rate,
-- shows what the board prints, sends typed text, pauses for uploads, follows an
-- unplugged board, and explains errors.
local SKETCH = "void setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n}\n"

return {
  before = function(T)
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8" },
      ports = { { address = "/dev/ttyUSB0", boards = { { "Arduino UNO", "arduino:avr:uno" } } } } })
  end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    local ino = dir .. "/Blink.ino"
    if T.phase == 1 then
      T.mkdir(dir)
      T.write_file(ino, SKETCH)
      T.write_file(dir .. "/sketch.yaml", "profiles:\n  uno:\n    fqbn: arduino:avr:uno\n    platforms:\n"
        .. "      - platform: arduino:avr (1.8.8)\n\ndefault_profile: uno\n")
      T.expect_restart()
      core.open_project(dir)
      return
    end

    local build = require "plugins.arduino.build"
    local monitor = require "plugins.arduino.serial_monitor"
    local SerialView = require "plugins.arduino.serial_view"
    local OutputView = require "plugins.arduino.output_view"
    local PanelBar = require "plugins.arduino.panel_bar"
    local bar = T.wait_until(function() return PanelBar.view and #PanelBar.view.tabs > 0 and PanelBar.view end, 5, "the bar")
    local function tab(name)
      for _, t in ipairs(bar.tabs) do if t.tab.text == name then return t end end
    end
    local function click_tab(name)
      local t = tab(name)
      bar:on_mouse_pressed("left", t.x + 2, t.y + 2, 1)
    end
    local function click(view, id)
      view:layout()
      for _, target in ipairs(view.targets) do
        if target.id == id then
          view:on_mouse_pressed("left", target.x + 2, target.y + 2, 1)
          return true
        end
      end
      T.check(false, "the Serial Monitor has " .. id)
    end
    local function has_line(text, kind)
      for _, line in ipairs(monitor.lines) do
        if line.text:find(text, 1, true) and (not kind or line.kind == kind) then return line end
      end
    end
    local function connected() return monitor.state() == "connected" end
    -- the fake board prints what is appended to its feed
    local fed = ""
    local function feed(text)
      fed = fed .. text
      T.fake_cli_set("serial_feed", fed)
    end

    -- the tab sits between Output and Terminal
    T.check(tab("Serial Monitor") ~= nil, "a Serial Monitor tab")
    T.check(tab("Output").x < tab("Serial Monitor").x and (not tab("Terminal") or tab("Serial Monitor").x < tab("Terminal").x),
      "between Output and Terminal")

    -- opening it connects to the sketch's port at the sketch's Serial.begin() rate
    click_tab("Serial Monitor")
    local view = SerialView.view
    T.check(view and view.visible, "the tab shows the Serial Monitor")
    T.eq(core.active_view, view, "its box has the keyboard")
    T.wait_until(function() return view.size.y > 50 end, 5, "the panel to open")
    T.check(math.abs(view.position.y + view.size.y - bar.position.y) <= 2, "right above the bar")
    T.wait_until(function() return has_line("Hello at 115200 baud", "rx") end, 10, "the board's greeting")
    T.check(connected(), "connected")
    T.match(T.fake_cli_calls(), "monitor %-p /dev/ttyUSB0 %-%-config baudrate=115200 %-%-quiet", "at 115200 baud")
    T.match(T.fake_cli_calls(), "%-l serial %-b arduino:avr:uno", "with the port's protocol and the board's settings")
    T.match(view:title(), "/dev/ttyUSB0 at 115200 baud", "the header says where")

    -- received text: a line still being written shows, then completes
    feed("Value: ")
    T.wait_until(function() return monitor.partial and monitor.partial.text == "Value: " end, 5, "the partial line")
    feed("42\r\n")
    T.wait_until(function() return has_line("Value: 42", "rx") end, 5, "the completed line")
    T.eq(monitor.partial, nil, "no partial line left")
    T.shot("serial-monitor")

    -- typed text is sent with the line ending (Newline by default)
    T.type("led on")
    T.key("return")
    T.wait_until(function() return has_line('got "led on\\n"') end, 5, "the board's answer")
    T.eq(view.input, "", "the box is emptied")
    -- another line ending, chosen like the Arduino IDE's menu
    click(view, "serial:line-ending")
    T.eq(core.active_view, core.command_view, "the line ending is chosen from a list")
    T.type("both")
    T.wait_until(function() return #core.command_view.suggestions == 1 end, 5, "the filtered list")
    T.key("return")
    T.eq(monitor.line_ending().id, "crlf", "Both NL & CR chosen")
    view:show(true)
    T.type("x")
    T.key("return")
    T.wait_until(function() return has_line('got "x\\r\\n"') end, 5, "the text with CR LF")
    monitor.set_line_ending("lf")
    -- Up brings back sent text
    T.key("up")
    T.eq(view.input, "x", "Up brings back the last sent text")
    T.key("up")
    T.eq(view.input, "led on", "and the one before")
    T.key("ctrl+backspace")
    T.eq(view.input, "", "Ctrl+Backspace empties the box")

    -- timestamps
    click(view, "serial:timestamps")
    T.check(monitor.timestamps(), "Timestamps turns them on")
    T.match(monitor.text(true), "%d%d:%d%d:%d%d%.%d%d%d  Value: 42", "lines carry their time")
    local ordered = true
    for i = 2, #monitor.lines do
      if monitor.lines[i].time < monitor.lines[i - 1].time then ordered = false end
    end
    T.check(ordered, "in order")
    T.shot("serial-timestamps")
    click(view, "serial:timestamps")
    T.check(not monitor.timestamps(), "and off")

    -- another baud rate: connects again, and is remembered for the sketch
    click(view, "serial:baud")
    T.eq(core.active_view, core.command_view, "the baud rate is chosen from a list")
    T.type("9600")
    T.wait_until(function() return #core.command_view.suggestions >= 1 end, 5, "the filtered rates")
    T.key("return")
    T.wait_until(function() return has_line("Hello at 9600 baud") end, 10, "the board at 9600 baud")
    T.eq(monitor.baud_for(dir), 9600, "the rate is remembered")
    -- until the sketch's Serial.begin() changes
    T.write_file(ino, (SKETCH:gsub("115200", "57600")))
    T.eq(monitor.baud_for(dir), 57600, "a changed Serial.begin() wins")
    T.write_file(ino, SKETCH)
    T.eq(monitor.baud_for(dir), 9600, "the chosen rate again for the old Serial.begin()")

    -- an upload pauses the monitor (the port is free), then it connects again
    view:show(true)
    core.set_active_view(core.root_view:get_primary_node().active_view)
    T.key("ctrl+u")
    T.check(monitor.state() == "paused", "uploading pauses the monitor")
    T.check(OutputView.view.visible and not view.visible, "the Output panel shows the upload")
    T.wait_until(function() return build.last and build.last.state ~= "running" end, 15, "the upload")
    T.eq(build.last.state, "done", "the upload succeeds (the port was free)")
    T.wait_until(connected, 10, "the monitor to connect again")
    T.check(view.visible and not OutputView.view.visible, "the Serial Monitor shows again")

    -- the board is unplugged and plugged in again
    T.fake_cli_set("ports", T.array())
    T.wait_until(function() return monitor.state() == "waiting" end, 10, "the monitor to notice")
    T.check(has_line("Disconnected", "error"), "it says the board is gone")
    T.match(view:title(), "waiting for /dev/ttyUSB0", "and waits for it")
    T.fake_cli_set("ports", { { address = "/dev/ttyUSB0", boards = { { "Arduino UNO", "arduino:avr:uno" } } } })
    T.wait_until(connected, 10, "the monitor to connect again by itself")

    -- Disconnect, and a port that cannot be opened
    click(view, "serial:disconnect")
    T.eq(monitor.state(), "disconnected", "Disconnect closes the port")
    T.check(has_line("Disconnected from /dev/ttyUSB0", "info"), "and says so")
    T.fake_cli_set("monitor_denied", true)
    click(view, "serial:connect")
    T.wait_until(function() return has_line("Could not connect", "error") end, 10, "the failed connection")
    local hint = has_line("allow it", "hint")
    T.eq(hint and hint.command, "arduino:allow-serial-port-access", "a hint offers to allow serial port access")
    T.shot("serial-denied")
    T.fake_cli_set("monitor_denied", false)

    -- Clear, the other tabs, Hide
    click(view, "serial:clear")
    T.eq(#monitor.lines, 0, "Clear empties the monitor")
    click_tab("Output")
    T.check(OutputView.view.visible and not view.visible, "Output replaces the Serial Monitor")
    click_tab("Serial Monitor")
    T.check(view.visible and not OutputView.view.visible, "and the other way round")
    click(view, "serial:hide")
    T.check(not view.visible, "Hide hides it")
    T.check(core.active_view ~= view, "and gives the keyboard back")
    T.check(bar.size.y > 0, "the bar stays to bring it back")
    T.no_errors()
  end,
}
