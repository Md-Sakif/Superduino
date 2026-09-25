-- Templates are optional; a starter or a library example can be chosen on the name step.
return {
  before = function(T) T.mkdir(T.home .. "/Arduino") end,
  run = function(T)
    local core = require "core"
    if T.phase == 1 then
      local v = T.open_wizard()
      T.key("return"); T.key("return"); T.type("uno"); T.key("return")
      T.eq(v.template, nil, "empty sketch by default")
      local button = v.current_layout.choose_template
      v:on_mouse_pressed("left", button.x + 2, button.y + 2, 1)
      local panel = v.panel
      T.check(panel and panel.filter ~= nil, "template picker opens")
      T.eq(T.selected(panel) or panel:get_list()[panel.selected].label, "Empty sketch", "Empty sketch is selected first")
      T.wait_until(function() return not panel.loading end, 10, "examples to load")
      T.eq(#panel.examples, 2, "library examples for the board are listed")
      T.type("blink")
      T.eq(panel:get_list()[panel.selected].label, "Blink", "search finds the Blink starter")
      T.shot("templates")
      T.key("return")
      T.eq(v.panel, nil, "choosing closes the picker")
      T.eq(v.template and v.template.name, "Blink", "Blink chosen")
      T.type("Blinky")
      T.expect_restart()
      T.key("return")
    elseif T.phase == 2 then
      local dir = T.home .. "/Arduino/Blinky"
      T.match(T.read_file(dir .. "/Blinky.ino") or "", "LED_BUILTIN", "the sketch has the Blink template")
      T.match(T.read_file(dir .. "/sketch.yaml") or "", "arduino:avr:uno", "and a build profile")
      -- now a library example with several files
      local v = T.open_wizard()
      T.key("return"); T.key("return"); T.type("uno"); T.key("return")
      v:choose_template()
      local panel = v.panel
      T.wait_until(function() return not panel.loading end, 10, "examples to load")
      T.type("softwareserial")
      T.key("return")
      T.eq(v.template and v.template.name, "SoftwareSerialExample", "example chosen")
      T.type("Radio")
      T.expect_restart()
      T.key("return")
    else
      local dir = T.home .. "/Arduino/Radio"
      T.match(T.read_file(dir .. "/Radio.ino") or "", "SoftwareSerial example", "the example became the main sketch")
      T.check(system.get_file_info(dir .. "/notes.h") ~= nil, "other example files were copied")
      T.check(not system.get_file_info(dir .. "/SoftwareSerialExample.ino"), "no leftover example main file")
      T.no_errors()
    end
  end,
}
