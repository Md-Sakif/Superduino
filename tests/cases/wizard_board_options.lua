-- After the board, its settings (e.g. ESP32 Partition Scheme, PSRAM) can be changed;
-- changed ones go into the profile's fqbn. Boards without settings skip the step.
return {
  before = function(T)
    T.mkdir(T.home .. "/Arduino")
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8", ["esp32:esp32"] = "3.3.11" }, details_fail = true })
  end,
  run = function(T)
    local keymap = require "core.keymap"
    if T.phase ~= 1 then
      local yaml = T.read_file(T.home .. "/Arduino/Wroom/sketch.yaml") or ""
      T.match(yaml, "fqbn: esp32:esp32:esp32:PSRAM=enabled\n", "profile has the board with its changed setting")
      T.match(yaml, "default_profile: esp32", "profile name comes from the board")
      T.no_errors()
      return
    end

    local v = T.open_wizard()
    local function tool(id)
      for _, link in ipairs(v.current_layout.tools or {}) do
        if link.id == id then return link end
      end
    end
    local function click(target) v:on_mouse_pressed("left", target.x + 2, target.y + 2, 1) end
    local function options_loaded()
      return T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "board settings")
    end

    -- settings that cannot be loaded do not block the project
    T.key("return"); T.key("return"); T.type("nano"); T.key("return")
    T.eq(v.step, 4, "Nano goes to the options step")
    options_loaded()
    T.check(v.board_options.error ~= nil, "the error is kept")
    T.check(v:page_buttons().next.enabled, "Next is enabled: the defaults are used")
    T.check(tool("tool:retry-options") ~= nil, "Try Again is offered")
    T.shot("options-error")
    T.fake_cli_set("details_fail", false)
    click(tool("tool:retry-options"))
    options_loaded()
    T.eq(v.board_options.error, nil, "Try Again loads the settings")
    T.eq(T.selected(v), "Processor", "Nano has a Processor setting")
    T.key("escape"); T.key("escape"); T.key("escape")
    T.eq(v.step, 1, "Esc goes back to the vendor step")

    -- ESP32 Dev Module
    T.type("espressif"); T.key("return")
    T.key("return")
    T.type("esp32 dev"); T.eq(T.selected(v), "ESP32 Dev Module", "board found")
    T.key("return")
    T.eq(v.step, 4, "options step")
    options_loaded()
    T.eq(#v:get_list(), 6, "all settings listed")
    T.eq(v:get_list()[4].detail, "Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)", "defaults preselected")
    T.eq(tool("tool:reset-options").enabled, false, "nothing to reset yet")
    T.eq(v:options_status(), "All settings are at their defaults.", "status says defaults")

    -- arrows change the selected setting in place
    for _ = 1, 4 do T.key("down") end
    T.eq(T.selected(v), "PSRAM", "PSRAM selected")
    T.key("right")
    T.eq(v:get_list()[5].detail, "Enabled", "right arrow picks the next value")
    T.key("right")
    T.eq(v:get_list()[5].detail, "Enabled", "the last value stays")
    T.match(v:get_list()[5].note or "", "default: Disabled", "changed settings show their default")

    -- Space opens all values of a setting, with search
    T.key("up")
    T.eq(T.selected(v), "Partition Scheme", "Partition Scheme selected")
    T.key("space")
    local panel = v.panel
    T.check(panel and panel.option and panel.option.option == "PartitionScheme", "Space opens the value list")
    T.eq(panel:get_list()[panel.selected].label, "Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)", "current value selected")
    T.type("huge")
    T.shot("option-values")
    T.key("return")
    T.eq(v.panel, nil, "choosing closes the list")
    T.eq(v:get_fqbn(), "esp32:esp32:esp32:PartitionScheme=huge_app,PSRAM=enabled", "fqbn has the changed settings")
    T.shot("options")

    -- Reset to Defaults, then a click opens a setting's values
    click(tool("tool:reset-options"))
    T.eq(v:get_fqbn(), "esp32:esp32:esp32", "reset restores the defaults")
    click(v.current_layout.rows[5])
    T.check(v.panel ~= nil, "clicking a setting opens its values")
    T.key("down"); T.key("return")
    T.eq(v:get_fqbn(), "esp32:esp32:esp32:PSRAM=enabled", "value picked with the mouse list")

    -- on to the name step and back: settings are kept
    T.key("return")
    T.eq(v.step, 5, "Enter continues to the name step")
    T.eq(v.current_layout.crumbs[4].text, "1 option changed", "the step bar sums up the settings")
    T.check(not keymap.on_key_pressed("space"), "Space is not taken on the name step")
    keymap.on_key_released("space")
    T.key("escape")
    T.eq(v.step, 4, "Esc goes back to the options step")
    T.eq(v:get_fqbn(), "esp32:esp32:esp32:PSRAM=enabled", "settings are kept")

    -- another board without settings skips the step, both ways
    T.key("escape")
    T.type("s3"); T.key("return")
    T.name_step(v)
    T.eq(v.current_layout.crumbs[4].text, "No options", "no settings for this board")
    T.key("escape")
    T.eq(v.step, 3, "Esc from the name step skips the empty options step")

    -- choosing the ESP32 again starts from its defaults
    T.type("esp32 dev"); T.key("return")
    options_loaded()
    T.eq(v:get_fqbn(), "esp32:esp32:esp32", "a changed board starts from the defaults")
    for _ = 1, 4 do T.key("down") end
    T.key("right")
    T.key("return")
    T.type("Wroom")
    T.expect_restart()
    T.key("return")
  end,
}
