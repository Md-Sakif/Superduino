-- The panel bar under the editor area has an Output tab that shows and hides
-- the Output panel; hiding the panel keeps the bar.
return {
  run = function(T)
    local core = require "core"
    local PanelBar = require "plugins.arduino.panel_bar"
    local OutputView = require "plugins.arduino.output_view"
    local treeview = require "plugins.treeview"
    local function style_divider() return math.max(1, require("core.style").divider_size) end
    local bar = T.wait_until(function() return PanelBar.view end, 5, "the panel bar")
    T.wait_until(function() return bar.size.y > 0 and #bar.tabs > 0 end, 5, "the bar to be laid out")
    local function click_tab()
      local t = bar.tabs[1]
      bar:on_mouse_pressed("left", t.x + 2, t.y + 2, 1)
    end

    -- placement: right of the left pane, just above the status bar
    T.eq(bar.tabs[1].tab.text, "Output", "one tab: Output")
    T.check(bar.position.x >= treeview.position.x + treeview.size.x - 1, "right of the left pane")
    T.eq(bar.position.x + bar.size.x, core.root_view.size.x, "to the right edge")
    -- (split nodes may leave a 1 px divider)
    T.check(math.abs(bar.position.y + bar.size.y - core.status_view.position.y) <= style_divider(),
      "just above the status bar")
    T.check(not (OutputView.view and OutputView.view.visible), "the Output panel starts hidden")

    -- the tab shows the panel above the bar
    click_tab()
    local output = OutputView.view
    T.check(output and output.visible, "clicking Output shows the panel")
    T.wait_until(function() return output.size.y > 50 end, 5, "the panel to open")
    T.check(math.abs(output.position.y + output.size.y - bar.position.y) <= 1, "the panel is right above the bar")
    T.eq(output.position.x, bar.position.x, "and as wide")
    T.check(bar.tabs[1].tab.active(), "the tab is marked active")
    T.shot("output-open")

    -- Hide in the panel hides it; the bar stays to bring it back
    local hide
    for _, link in ipairs(output.links) do if link.id == "output:hide" then hide = link end end
    output:on_mouse_pressed("left", hide.x + 2, hide.y + 2, 1)
    T.eq(output.visible, false, "Hide hides the panel")
    T.wait_until(function() return output.size.y < 1 end, 5, "the panel to close")
    T.check(bar.size.y > 0, "the bar stays")
    T.check(not bar.tabs[1].tab.active(), "the tab is no longer active")
    T.shot("output-hidden")
    click_tab()
    T.check(output.visible, "the tab brings the panel back")
    click_tab()
    T.eq(output.visible, false, "and hides it again")
    T.no_errors()
  end,
}
