-- The Serial Plotter tab plots the numbers the board prints, sharing the Serial
-- Monitor's connection: series by label or position, a legend that hides
-- lines, pause, the number of points shown, and uploads in between.
local SKETCH = "void setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n}\n"

return {
  before = function(T)
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8" },
      ports = { { address = "/dev/ttyUSB0", boards = { { "Arduino UNO", "arduino:avr:uno" } } } } })
  end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    if T.phase == 1 then
      T.mkdir(dir)
      T.write_file(dir .. "/Blink.ino", SKETCH)
      T.write_file(dir .. "/sketch.yaml", "profiles:\n  uno:\n    fqbn: arduino:avr:uno\n    platforms:\n"
        .. "      - platform: arduino:avr (1.8.8)\n\ndefault_profile: uno\n")
      T.expect_restart()
      core.open_project(dir)
      return
    end

    local build = require "plugins.arduino.build"
    local monitor = require "plugins.arduino.serial_monitor"
    local plot = require "plugins.arduino.serial_plot"
    local PlotView = require "plugins.arduino.serial_plot_view"
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
      T.check(false, "the Serial Plotter has " .. id)
    end
    local fed = ""
    local function feed(text)
      fed = fed .. text
      T.fake_cli_set("serial_feed", fed)
    end
    local function series(name)
      for _, s in ipairs(plot.series) do if s.name == name then return s end end
    end
    local function names()
      local list = {}
      for _, s in ipairs(plot.series) do table.insert(list, s.name) end
      return table.concat(list, ",")
    end

    -- how lines are read
    local function parsed(text)
      local fields = plot.parse(text)
      if not fields then return "message" end
      local out = {}
      for _, f in ipairs(fields) do table.insert(out, f.name .. "=" .. f.value) end
      return table.concat(out, " ")
    end
    T.eq(parsed("1 2 3"), "Value 1=1 Value 2=2 Value 3=3", "bare numbers are named by position")
    T.eq(parsed("1,-2.5\t3e2"), "Value 1=1 Value 2=-2.5 Value 3=300.0", "commas and tabs separate too")
    T.eq(parsed("temp:21.5,hum:40"), "temp=21.5 hum=40", "label:value")
    T.eq(parsed("Temp: 21.5 Hum: 40"), "Temp=21.5 Hum=40", "a label printed before its number")
    T.eq(parsed("Hello at 115200 baud"), "message", "text is a message, not a sample")
    T.eq(parsed(""), "message", "empty lines too")
    T.eq(parsed("Temp:"), "message", "a label without a number too")

    -- the tab, after the Serial Monitor's
    T.check(tab("Serial Plotter") ~= nil, "a Serial Plotter tab")
    T.check(tab("Serial Monitor").x < tab("Serial Plotter").x
      and (not tab("Terminal") or tab("Serial Plotter").x < tab("Terminal").x), "between Serial Monitor and Terminal")

    -- opening it connects, like the Serial Monitor
    click_tab("Serial Plotter")
    local view = PlotView.view
    T.check(view and view.visible, "the tab shows the Serial Plotter")
    T.wait_until(function() return view.size.y > 50 end, 5, "the panel to open")
    T.wait_until(function() return monitor.state() == "connected" end, 10, "the connection")
    T.match(view:title(), "Serial Plotter: /dev/ttyUSB0 at 115200 baud", "the header says where")
    T.wait_until(function()
      for _, line in ipairs(monitor.lines) do if line.text:find("Hello at", 1, true) then return true end end
    end, 10, "the board's greeting")
    T.eq(#plot.series, 0, "the greeting is not plotted")
    T.shot("plotter-empty")

    -- labelled values
    local text = {}
    for i = 1, 60 do
      table.insert(text, string.format("temp:%.2f hum:%d\r\n", 20 + 5 * math.sin(i / 6), 40 + (i % 10)))
    end
    feed(table.concat(text))
    T.wait_until(function() return plot.count >= 60 end, 10, "60 samples")
    T.eq(names(), "temp,hum", "a series per label, in order")
    T.eq(series("hum").last, 40, "with the latest value")
    local first, last = plot.range()
    T.eq(last - first + 1, 60, "all 60 shown (fewer than the points shown)")
    T.match(table.concat((function()
      local l = {} for _, line in ipairs(monitor.lines) do table.insert(l, line.text) end return l
    end)(), "\n"), "temp:20", "the Serial Monitor gets the same lines")
    T.shot("plotter")

    -- the legend hides and shows a line
    click(view, "series:1")
    T.check(series("temp").hidden, "clicking a name hides its line")
    local low, high = plot.bounds()
    T.check(low >= 40 and high <= 49, "the scale follows the shown lines")
    click(view, "series:1")
    T.check(not series("temp").hidden, "and shows it again")

    -- pause freezes the view while samples still arrive
    click(view, "plot:pause")
    local _, frozen = plot.range()
    feed("temp:1 hum:2\r\n")
    T.wait_until(function() return plot.count >= 61 end, 5, "another sample")
    T.eq(select(2, plot.range()), frozen, "paused: the view stays")
    click(view, "plot:pause")
    T.eq(select(2, plot.range()), plot.count, "resumed: it follows again")

    -- points shown
    click(view, "plot:window")
    T.eq(core.active_view, core.command_view, "the points shown are chosen from a list")
    T.type("50")
    T.wait_until(function() return #core.command_view.suggestions >= 1 end, 5, "the filtered list")
    T.key("return")
    T.eq(plot.window(), 50, "50 points")
    first, last = plot.range()
    T.eq(last - first + 1, 50, "the last 50 samples are shown")

    -- connected, the plotter locks uploading and its baud rate like the monitor
    local function link(id)
      view:layout()
      for _, l in ipairs(view.links) do if l.id == id then return l end end
    end
    T.eq(link("plot:baud").enabled, false, "the baud rate is locked while connected")
    core.set_active_view(core.root_view:get_primary_node().active_view)
    T.key("ctrl+u")
    T.wait(0.3)
    T.eq(build.last, nil, "Ctrl+U does not upload while connected")
    T.check(view.visible, "the plotter stays")
    click(view, "plot:disconnect")
    T.eq(monitor.state(), "disconnected", "Disconnect in the plotter frees the port")
    T.check(link("plot:baud").enabled, "the baud rate unlocks")
    click(view, "plot:connect")
    T.wait_until(function() return monitor.state() == "connected" end, 10, "the connection again")

    -- Clear, and the shared connection between the tabs
    click(view, "plot:clear")
    T.eq(#plot.series, 0, "Clear removes the lines")
    feed("1 2\r\n")
    T.wait_until(function() return #plot.series == 2 end, 5, "unlabelled values")
    T.eq(names(), "Value 1,Value 2", "named by position")
    click_tab("Serial Monitor")
    T.check(SerialView.view.visible and not view.visible, "the Serial Monitor replaces the plotter")
    T.eq(monitor.state(), "connected", "on the same connection")
    click_tab("Serial Plotter")
    click(view, "plot:hide")
    T.check(not view.visible, "Hide hides it")
    T.no_errors()
  end,
}
