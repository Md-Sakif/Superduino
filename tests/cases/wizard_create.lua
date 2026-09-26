-- Happy path: Arduino > AVR > UNO > name creates the sketch with a build profile and opens it.
return {
  before = function(T) T.mkdir(T.home .. "/Arduino") end,
  run = function(T)
    local core = require "core"
    if T.phase == 1 then
      local v = T.open_wizard()
      T.eq(v.step, 1, "starts at the vendor step")
      T.eq(T.selected(v), "Arduino", "Arduino is first")
      T.key("return")
      T.eq(v.step, 2, "enter moves to the architecture step")
      T.eq(T.selected(v), "Arduino AVR Boards", "installed family first")
      T.key("return")
      T.type("uno")
      T.eq(T.selected(v), "Arduino UNO", "typing uno selects Arduino UNO, not Arduino BT")
      T.key("return")
      T.name_step(v)
      T.eq(v.choice[4], "none", "UNO has no settings: the options step is skipped")
      T.type("Blink")
      T.eq(v.location, T.home .. "/Arduino", "location is the sketchbook")
      T.shot("name-step")
      T.expect_restart()
      T.key("return")
    else
      local dir = T.home .. "/Arduino/Blink"
      T.eq(core.root_project() and core.root_project().path, dir, "new project is open")
      T.eq(core.active_view.doc and core.active_view.doc.abs_filename, dir .. "/Blink.ino", "sketch is open")
      local yaml = T.read_file(dir .. "/sketch.yaml") or ""
      T.match(yaml, "fqbn: arduino:avr:uno", "profile has the board")
      T.match(yaml, "default_profile: uno", "profile is the default")
      for _, view in ipairs(core.root_view.root_node:get_children()) do
        T.check(tostring(view) ~= "NewProjectView", "the New Project page is closed")
      end
      T.no_errors()
    end
  end,
}
