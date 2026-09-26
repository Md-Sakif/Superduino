-- Applying Board Settings updates a sketch.yaml that is open in the editor, and
-- does not overwrite one with unsaved edits.
return {
  before = function(T) T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8" } }) end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    local yaml_path = dir .. "/sketch.yaml"
    if T.phase == 1 then
      T.mkdir(dir)
      local fp = io.open(dir .. "/Blink.ino", "w"); fp:write("void setup() {}\nvoid loop() {}\n"); fp:close()
      fp = io.open(yaml_path, "w")
      fp:write("profiles:\n  nano:\n    fqbn: arduino:avr:nano\n    platforms:\n      - platform: arduino:avr (1.8.8)\n\n"
        .. "default_profile: nano\n")
      fp:close()
      T.expect_restart()
      core.open_project(dir)
      return
    end

    -- sketch.yaml open in a tab; Board Settings opens next to it and hides it
    local doc_view = core.root_view:open_doc(core.open_doc(yaml_path))
    local doc = doc_view.doc
    local function open_settings()
      T.command("arduino:board-settings")
      local v = T.wait_until(function()
        local view = core.active_view
        return tostring(view) == "NewProjectView" and view.edit and not view.loading and view
      end, 10, "Board Settings")
      T.wait_until(function() return v.board_options and not v.board_options.loading end, 10, "settings")
      return v
    end
    local v = open_settings()
    T.key("right")
    T.key("return")
    T.wait_until(function() return core.active_view ~= v end, 10, "Apply and Close")
    T.match(T.read_file(yaml_path) or "", "fqbn: arduino:avr:nano:cpu=atmega328old", "the file was written")
    T.wait_until(function() return doc:get_text(3, 1, 3, math.huge):find("atmega328old", 1, true) end, 5,
      "the open sketch.yaml to show the change")
    T.eq(doc:get_text(3, 1, 3, math.huge), "    fqbn: arduino:avr:nano:cpu=atmega328old", "the open tab shows the new fqbn")
    T.check(not doc:is_dirty(), "and has no unsaved changes")

    -- unsaved edits in the open sketch.yaml are not overwritten
    doc:insert(1, 1, "# my edit\n")
    v = open_settings()
    T.key("right")
    T.key("return")
    T.wait_until(function() return v.message and not v.creating end, 5, "the save to be refused")
    T.match(v.message or "", "unsaved changes", "explains why it did not save")
    T.eq(core.active_view, v, "the page stays open")
    T.check(not (T.read_file(yaml_path) or ""):find("cpu=atmega168", 1, true), "the file was not written")
    T.eq(doc:get_text(1, 1, 1, math.huge), "# my edit", "the edit is still there")
    T.no_errors()
  end,
}
