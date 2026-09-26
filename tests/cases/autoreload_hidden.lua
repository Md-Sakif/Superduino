-- A file changed on disk while its tab was hidden is reloaded when the tab is
-- shown again; with unsaved edits it asks once, and "No" keeps the edits.
-- The files are inside the open project, so their doc.filename is relative
-- (and the editor's working directory is not the project).
return {
  run = function(T)
    local core = require "core"
    local command = require "core.command"
    local function write(path, text) local fp = io.open(path, "w"); fp:write(text); fp:close() end
    local dir = T.home .. "/project"
    local a, b = dir .. "/a.txt", dir .. "/b.txt"
    if T.phase == 1 then
      T.mkdir(dir)
      write(a, "old a\n"); write(b, "b\n")
      T.expect_restart()
      core.open_project(dir)
      return
    end
    local view_a = core.root_view:open_doc(core.open_doc(a))
    local view_b = core.root_view:open_doc(core.open_doc(b))
    local node = core.root_view.root_node:get_node_for_view(view_a)
    T.eq(core.active_view, view_b, "a.txt is hidden behind b.txt")
    T.eq(view_a.doc.filename, "a.txt", "the doc's filename is relative to the project")
    T.check(system.absolute_path(".") ~= dir, "the working directory is not the project")

    -- file times may only have a resolution of one second
    T.wait(1.1)
    write(a, "new a\n")
    T.wait(0.3)
    T.eq(view_a.doc:get_text(1, 1, 1, math.huge), "old a", "a hidden tab is not watched")
    node:set_active_view(view_a)
    T.eq(view_a.doc:get_text(1, 1, 1, math.huge), "new a", "showing the tab reloads it")

    -- with unsaved edits: asks, and No keeps them without asking again
    view_a.doc:insert(1, 1, "edit ")
    node:set_active_view(view_b)
    T.wait(1.1)
    write(a, "newer a\n")
    node:set_active_view(view_a)
    T.check(core.nag_view.visible, "asks before reloading over unsaved edits")
    command.perform("dialog:select-no")
    T.eq(view_a.doc:get_text(1, 1, 1, math.huge), "edit new a", "No keeps the edits")
    node:set_active_view(view_b)
    node:set_active_view(view_a)
    T.check(not core.nag_view.visible, "and does not ask again for the same change")
    T.no_errors()
  end,
}
