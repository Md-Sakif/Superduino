-- Starting without arguments shows the welcome screen with no project.
return {
  run = function(T)
    local core = require "core"
    T.wait_until(function() return core.active_view end, 5, "an active view")
    T.eq(tostring(core.active_view), "EmptyView", "welcome screen is shown")
    T.eq(#core.projects, 0, "no project is open")

    local treeview
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if tostring(view) == "TreeView" then treeview = view end
    end
    T.check(treeview ~= nil, "tree view exists")
    T.wait_until(function() return treeview.size.x == 0 end, 3, "sidebar to collapse")

    local ev = core.active_view
    T.wait_until(function() return ev.items and #ev.items > 0 end, 3, "welcome rows")
    local titles = {}
    for _, header in ipairs(ev.current_layout.headers) do table.insert(titles, header.text) end
    -- "Needs Attention" only appears when something needs fixing
    T.eq(table.concat(titles, ","), "Start,Arduino CLI,USB Access,Recent", "welcome sections in order")
    T.eq(ev.items[1].label, "Create New Project...", "first action is Create New Project")
    T.shot("welcome")
    T.no_errors()
  end,
}
