-- Opening files from the tree, Open File and Save As inside a project do not
-- warn about deprecated functions (Lite XL's own code used to call them).
return {
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    if T.phase == 1 then
      T.mkdir(dir)
      for _, name in ipairs({ "Blink.ino", "notes.txt" }) do
        local fp = io.open(dir .. "/" .. name, "w"); fp:write("// " .. name .. "\n"); fp:close()
      end
      T.expect_restart()
      core.open_project(dir)
      return
    end

    -- open a file from the tree view
    local treeview = require "plugins.treeview"
    T.wait_until(function() return treeview:set_selection_to_path(dir .. "/Blink.ino") end, 10, "the file in the tree")
    core.set_active_view(treeview)
    T.command("treeview:open")
    T.wait_until(function() return core.active_view.doc and core.active_view.doc.abs_filename == dir .. "/Blink.ino" end,
      5, "Blink.ino to open from the tree")
    T.eq(core.active_view.doc.filename, "Blink.ino", "the tree opens it relative to the project")

    -- Open File with a path relative to the project
    T.command("core:open-file")
    core.command_view:set_text("notes.txt")
    core.command_view:submit()
    T.wait_until(function() return core.active_view.doc and core.active_view.doc.abs_filename == dir .. "/notes.txt" end,
      5, "notes.txt to open")

    -- Save As with a relative name saves into the project
    T.command("doc:save-as")
    core.command_view:set_text("copy.txt")
    core.command_view:submit()
    T.wait_until(function() return system.get_file_info(dir .. "/copy.txt") end, 5, "copy.txt to be saved")
    T.eq(core.active_view.doc.abs_filename, dir .. "/copy.txt", "saved in the project folder")

    local warnings = table.concat(T.problems(), " | ")
    T.check(not warnings:find("deprecated", 1, true), "no deprecation warnings: " .. warnings)
    T.no_errors()
  end,
}
