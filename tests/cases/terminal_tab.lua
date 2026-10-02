-- The panel bar's Terminal tab opens a shell in the project folder above the
-- bar; Output and Terminal show one at a time.
return {
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    if T.phase == 1 then
      T.mkdir(dir)
      local fp = io.open(dir .. "/Blink.ino", "w"); fp:write("void setup() {}\nvoid loop() {}\n"); fp:close()
      T.expect_restart()
      core.open_project(dir)
      return
    end

    local PanelBar = require "plugins.arduino.panel_bar"
    local OutputView = require "plugins.arduino.output_view"
    local bar = T.wait_until(function() return PanelBar.view and #PanelBar.view.tabs > 0 and PanelBar.view end, 5, "the bar")
    local function tab(name)
      for _, t in ipairs(bar.tabs) do if t.tab.text == name then return t end end
    end
    local function click(name)
      local t = tab(name)
      bar:on_mouse_pressed("left", t.x + 2, t.y + 2, 1)
    end
    -- all text on the terminal's screen
    local function screen()
      local text = {}
      for _, line in ipairs(core.terminal_view.terminal:lines()) do
        local parts = {}
        for i = 2, #line, 2 do table.insert(parts, line[i]) end
        table.insert(text, table.concat(parts))
      end
      return table.concat(text, "\n")
    end

    T.check(tab("Output") ~= nil and tab("Terminal") ~= nil, "Output and Terminal tabs")
    T.check(tab("Terminal").x > tab("Output").x, "Terminal is right of Output")

    -- Terminal opens a shell in the project folder
    click("Terminal")
    T.check(tab("Terminal").tab.active(), "the Terminal tab is active")
    local view = T.wait_until(function() return core.terminal_view and core.terminal_view.terminal and core.terminal_view end,
      10, "the shell to start")
    T.eq(core.active_view, view, "the shell has the keyboard")
    T.wait_until(function() return view.size.y > 50 end, 5, "the drawer to open")
    T.check(math.abs(view.position.y + view.size.y - bar.position.y) <= 2, "the terminal is right above the bar")
    T.eq(view.position.x, bar.position.x, "and as wide")
    view:input("echo SUPERDUINO_$((6*7)); pwd\r")
    T.wait_until(function() return screen():find("SUPERDUINO_42", 1, true) end, 10, "the command's output")
    -- (a long path wraps at the terminal's width)
    T.check(screen():gsub("\n", ""):find(dir, 1, true) ~= nil, "the shell runs in the project folder")
    T.shot("terminal")

    -- Output replaces the terminal, and the other way round
    click("Output")
    T.check(OutputView.view.visible, "Output shows the Output panel")
    T.check(not tab("Terminal").tab.active(), "and closes the terminal")
    click("Terminal")
    T.check(tab("Terminal").tab.active(), "Terminal opens it again")
    T.check(not OutputView.view.visible, "and hides Output")
    T.check(screen():find("SUPERDUINO_42", 1, true) ~= nil, "the same shell, with its history")
    click("Terminal")
    T.check(not tab("Terminal").tab.active(), "clicking the active tab closes it")

    -- the header has the title and Hide, like the Output panel
    click("Terminal")
    T.wait_until(function() return view.size.y > 50 end, 5, "the drawer to open again")
    local hide_x = view.position.x + view.size.x - require("core.style").padding.x - 10
    view:on_mouse_pressed("left", hide_x, view.position.y + 5, 1)
    T.check(not tab("Terminal").tab.active(), "Hide in the header hides the terminal")
    T.check(bar.size.y > 0, "the bar stays to bring it back")
    T.no_errors()
  end,
}
