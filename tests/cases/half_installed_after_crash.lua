-- An install interrupted by a crash is shown as half installed and can be repaired from the welcome screen.
return {
  before = function(T)
    require("core.storage").save("arduino", "installs",
      { ["arduino:samd"] = { name = "Arduino SAMD Boards (32-bits ARM Cortex-M0+)", state = "installing" } })
  end,
  run = function(T)
    local core = require "core"
    local ev = core.active_view
    T.wait_until(function() return ev.items and #ev.items > 0 end, 5, "welcome rows")
    local titles = {}
    for _, header in ipairs(ev.current_layout.headers) do table.insert(titles, header.text) end
    T.match(table.concat(titles, ","), "Needs Attention", "welcome shows Needs Attention")
    local repair
    for _, item in ipairs(ev.items) do
      if item.label:find("^Repair") then repair = item end
    end
    T.check(repair ~= nil, "offers Repair")
    T.shot("needs-attention")
    repair.run()
    local v = T.wait_until(function()
      local view = core.active_view
      return tostring(view) == "NewProjectView" and view.panel and view
    end, 10, "repair page")
    T.eq(v.panel.mode, "repair", "opens in repair mode")
    T.eq(v.panel.state, "incomplete", "explains it is half installed")
    T.wait_until(function() return not v.loading end, 10, "boards to load")
    T.key("return")
    T.wait_until(function() return v.panel == nil end, 20, "repair to finish")
    T.eq(#require("plugins.arduino.project").incomplete_installs(), 0, "repaired")
    T.eq(v.step, 3, "continues with the board step")
  end,
}
