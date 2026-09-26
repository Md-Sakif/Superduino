-- The board of an open sketch is shown in the Board panel of the left pane and can
-- be changed on the Board Settings page; sketch.yaml keeps everything that did not change.
local YAML = [[
# notes about this sketch
profiles:
  uno:
    fqbn: arduino:avr:uno
    platforms:
      - platform: arduino:avr (1.8.6)
    libraries:
      - Servo (1.3.0)

  debug:
    fqbn: arduino:avr:nano:cpu=atmega168
    platforms:
      - platform: arduino:avr (1.8.8)

default_profile: uno
]]

return {
  before = function(T)
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8", ["esp32:esp32"] = "3.3.11" } })
  end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    if T.phase == 1 then
      T.mkdir(dir)
      local fp = io.open(dir .. "/Blink.ino", "w"); fp:write("void setup() {}\nvoid loop() {}\n"); fp:close()
      fp = io.open(dir .. "/sketch.yaml", "w"); fp:write(YAML); fp:close()
      T.expect_restart()
      core.open_project(dir)
      return
    end

    local BoardPanel = require "plugins.arduino.board_panel"
    -- the panel's text: message, rows, then settings
    local function panel_text()
      local content = BoardPanel.describe()
      if not content then return "" end
      local parts = { content.message }
      for _, row in ipairs(content.rows) do table.insert(parts, row.label .. " " .. row.value) end
      for _, line in ipairs(content.settings) do table.insert(parts, line[1]) end
      return table.concat(parts, " | ")
    end
    -- clicks a row ("change:1".."change:3") or the configuration link ("change:options") of the panel
    local function click_panel(id)
      local panel = BoardPanel.view
      for _, target in ipairs(panel.current_layout.targets) do
        if target.id == id then
          panel:on_mouse_pressed("left", target.x + 2, panel.position.y + target.y + 2, 1)
          return true
        end
      end
      T.check(false, "the panel has a button " .. id)
    end
    local function yaml() return T.read_file(dir .. "/sketch.yaml") or "" end
    local function open_settings()
      T.command("arduino:board-settings")
      return T.wait_until(function()
        local v = core.active_view
        return tostring(v) == "NewProjectView" and v.edit and not v.loading and v
      end, 10, "Board Settings")
    end
    local function saved(v)
      T.wait_until(function() return core.active_view ~= v end, 10, "saving to close the page")
    end

    local UNO = "Vendor Arduino | Family Arduino AVR Boards | Board Arduino UNO"
    T.wait_until(function() return panel_text() == UNO end, 10, "the board in the panel")
    T.eq(panel_text(), UNO, "the panel shows vendor, family and board by name")
    T.wait_until(function() return BoardPanel.view.current_layout.no_options_y end, 10, "UNO settings")
    T.eq(BoardPanel.view.current_layout.wide, nil, "no Change Configuration for a board without options")
    local treeview = require "plugins.treeview"
    local panel = BoardPanel.view
    T.check(panel ~= nil, "the panel was added")
    local tree_node = core.root_view.root_node:get_node_for_view(treeview)
    local panel_node = panel and core.root_view.root_node:get_node_for_view(panel)
    T.check(panel_node and panel_node.locked and panel_node.locked.y, "the panel has its own height")
    T.check(panel and panel.position.x == treeview.position.x and panel.position.y > treeview.position.y,
      "the panel is in the left pane, under the file tree")
    T.check(panel and panel.size.y > 0, "the panel is visible")
    T.check(tree_node ~= panel_node, "tree and panel are separate")

    -- clicking a row opens the page on its step
    click_panel("change:3")
    local v = T.wait_until(function()
      local view = core.active_view
      return tostring(view) == "NewProjectView" and view.edit and not view.loading and view
    end, 10, "Board Settings from the panel")
    T.eq(v.step, 3, "clicking the board opens the board step")
    click_panel("change:1")
    T.eq(v.step, 1, "clicking the vendor goes to the vendor step on the open page")
    v:on_mouse_pressed("left", v.current_layout.crumbs[4].x + 2, v.current_layout.crumbs[4].y + 2, 1)

    -- UNO has no settings; the page is on the options step with Apply
    v = open_settings()
    T.eq(v.step, 4, "opens on the options step")
    T.eq(v:get_name(), "Board: Blink", "tab names the sketch")
    T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "settings")
    T.eq(#v:get_list(), 0, "UNO has no settings")
    T.eq(v:page_buttons().next.text, "Close", "nothing changed: only Close")
    T.eq(v:page_buttons().extra, nil, "and no Apply")
    T.shot("uno")

    -- another board of the same family, with a changed setting
    local crumb = v.current_layout.crumbs[3]
    v:on_mouse_pressed("left", crumb.x + 2, crumb.y + 2, 1)
    T.eq(v.step, 3, "the step bar goes to the board step")
    T.type("nano"); T.key("return")
    T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "Nano settings")
    T.eq(T.selected(v), "Processor", "Nano settings listed")
    T.key("right")
    -- a change offers Apply and Apply and Close; Apply saves and keeps the page open
    T.eq(v:page_buttons().next.text, "Apply and Close", "a change can be applied and closed")
    T.eq(v:page_buttons().extra and v:page_buttons().extra.text, "Apply", "or only applied")
    local apply = v.current_layout.extra
    v:on_mouse_pressed("left", apply.x + 2, apply.y + 2, 1)
    T.wait_until(function() return not v.creating end, 10, "applying")
    T.eq(core.active_view, v, "Apply keeps the page open")
    T.match(v.message or "", "Saved to sketch.yaml", "says it was saved")
    T.eq(v.edit.sketch.profile.name, "nano", "the page knows the renamed profile")
    T.eq(v:page_buttons().next.text, "Close", "applied: back to only Close")
    T.key("return")
    saved(v)
    local text = yaml()
    T.match(text, "\n  nano:\n    fqbn: arduino:avr:nano:cpu=atmega328old\n", "profile named after the new board")
    T.match(text, "%- platform: arduino:avr %(1%.8%.6%)", "the pinned platform version is kept")
    T.match(text, "%- Servo %(1%.3%.0%)", "libraries are kept")
    T.match(text, "^# notes about this sketch", "comments are kept")
    T.match(text, "  debug:\n    fqbn: arduino:avr:nano:cpu=atmega168\n", "other profiles are kept")
    T.match(text, "default_profile: nano\n", "the default follows the rename")
    T.wait_until(function() return panel_text():find("Processor", 1, true) end, 5, "the panel to update")
    T.eq(panel_text(), "Vendor Arduino | Family Arduino AVR Boards | Board Arduino Nano | Processor: ATmega328P (Old Bootloader)",
      "the panel shows the new board and its changed setting")
    T.wait_until(function() return BoardPanel.view.current_layout.wide end, 5, "Change Configuration")
    T.shot("panel")

    -- Change Configuration reopens the page on the options step with the saved choice;
    -- then a board of another family
    click_panel("change:options")
    v = T.wait_until(function()
      local view = core.active_view
      return tostring(view) == "NewProjectView" and view.edit and not view.loading and view
    end, 10, "Board Settings from Change Configuration")
    T.eq(v.step, 4, "Change Configuration opens the options step")
    T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "settings")
    T.eq(v:get_list()[1].detail, "ATmega328P (Old Bootloader)", "the saved setting is chosen")
    crumb = v.current_layout.crumbs[1]
    v:on_mouse_pressed("left", crumb.x + 2, crumb.y + 2, 1)
    T.type("espressif"); T.key("return"); T.key("return")
    T.type("esp32 dev"); T.key("return")
    T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "ESP32 settings")
    for _ = 1, 4 do T.key("down") end
    T.key("right")
    T.shot("esp32")
    T.key("return")
    saved(v)
    text = yaml()
    T.match(text, "\n  esp32:\n    fqbn: esp32:esp32:esp32:PSRAM=enabled\n    platforms:\n"
      .. "      %- platform: esp32:esp32 %(3%.3%.11%)\n        platform_index_url: [^\n]+\n    libraries:\n",
      "the family's platforms replace the old ones, libraries follow")
    T.check(not text:find("arduino:avr (1.8.6)", 1, true), "the old platform is gone from this profile")
    T.match(text, "  debug:\n", "other profiles are still kept")

    -- a sketch without sketch.yaml: "Set Board..." creates the profile
    os.remove(dir .. "/sketch.yaml")
    T.wait_until(function() return panel_text() == "No board chosen yet." end, 5, "no board in the panel")
    T.wait_until(function() return BoardPanel.view.current_layout.wide.text == "Set Board..." end, 5,
      "the panel to offer Set Board")
    v = open_settings()
    T.eq(v.step, 1, "starts at the vendor step")
    T.key("return"); T.key("return"); T.type("uno"); T.key("return")
    T.key("return")
    saved(v)
    T.match(yaml(), "fqbn: arduino:avr:uno\n", "a profile was created")
    T.no_errors()
  end,
}
