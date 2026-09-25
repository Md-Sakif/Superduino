-- Missing sketchbook folder: never created silently; Create Folder does it on request.
return {
  run = function(T)
    local core = require "core"
    local v = T.open_wizard()
    T.key("return"); T.key("return"); T.key("return")
    T.eq(v.step, 4, "name step")
    T.eq(v.location, T.home .. "/Arduino", "sketchbook location")
    T.check(not v:location_exists(), "the sketchbook folder does not exist yet")
    T.check(v.current_layout.create_folder ~= nil, "Create Folder is offered")
    T.type("First")
    T.key("return")
    T.match(v.message or "", "does not exist", "creating is refused with an explanation")
    T.check(not system.get_file_info(T.home .. "/Arduino"), "nothing was created")
    T.shot("missing-folder")
    local button = v.current_layout.create_folder
    v:on_mouse_pressed("left", button.x + 2, button.y + 2, 1)
    T.check(v:location_exists(), "Create Folder created it")
    T.wait(0.1)
    T.eq(v.current_layout.create_folder, nil, "the button goes away")
    -- a nested folder that does not exist yet can be chosen too
    v.location = T.home .. "/Projects/Arduino"
    T.check(not v:location_exists(), "another missing folder")
    T.key("return")
    T.match(v.message or "", "does not exist", "refused again")
  end,
}
