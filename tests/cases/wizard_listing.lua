-- Where "Add Vendor by URL" appears, hints for empty searches, and deprecated families.
return {
  before = function(T)
    T.fake_cli({ platforms = { ["Intel:arc32"] = { maintainer = "Intel", deprecated = true, latest = "2.0.6",
      name = "[DEPRECATED] Intel Curie Boards", boards = { { "Arduino/Genuino 101", "Intel:arc32:arduino_101" } } } } })
  end,
  run = function(T)
    local style = require "core.style"
    local v = T.open_wizard()
    local function tool_ids()
      local ids = {}
      for _, link in ipairs(v.current_layout.tools or {}) do table.insert(ids, link.id .. "=" .. link.text) end
      table.sort(ids)
      return table.concat(ids, ",")
    end
    T.wait(0.1)
    T.eq(tool_ids(), "tool:indexes=Add Vendor by URL...,tool:refresh=Refresh", "vendor step: Add Vendor by URL and Refresh")

    -- a vendor whose families are all deprecated is listed last and dimmed
    local list = v:get_list()
    local last = list[#list]
    T.eq(last.label, "Intel", "deprecated-only vendor is listed last")
    T.eq(last.detail, "deprecated", "and marked deprecated")
    T.check(last.color == style.dim, "and dimmed")

    -- empty search on the vendor step
    T.type("zzz"); T.wait(0.1)
    local empty = v.current_layout.empty
    T.check(empty ~= nil and #empty.links == 1 and empty.links[1].text == "Add Vendor by URL...",
      "no match on the vendor step suggests Add Vendor by URL")
    T.shot("vendor-empty")
    v:on_mouse_pressed("left", empty.links[1].x + 2, empty.links[1].y + 2, 1)
    T.check(v.panel and v.panel.input ~= nil, "the hint opens the Add Vendor by URL panel")
    T.key("escape"); T.key("escape")
    T.eq(v.panel, nil, "panel closed")
    T.key("escape")
    T.eq(v.filter, "", "search cleared")

    -- architecture step: only Refresh; deprecated family listed last with its reason
    T.key("return"); T.wait(0.1)
    T.eq(tool_ids(), "tool:refresh=Refresh", "architecture step: only Refresh")
    list = v:get_list()
    last = list[#list]
    T.eq(last.label, "Arduino Mbed OS Boards", "deprecated family is listed, without the [DEPRECATED] prefix")
    T.eq(last.detail, "not installed, deprecated", "marked deprecated")
    T.eq(last.note, "Please install standalone packages", "shows the reason from the index")
    T.shot("arch-deprecated")

    T.type("zzz"); T.wait(0.1)
    empty = v.current_layout.empty
    local texts = {}
    for _, link in ipairs(empty and empty.links or {}) do table.insert(texts, link.text) end
    T.eq(table.concat(texts, "|"), "Refresh the board list|Add Vendor by URL...",
      "no match on the architecture step suggests Refresh or Add Vendor by URL")
    T.shot("arch-empty")
    T.key("escape")

    -- installing a deprecated family warns about it
    T.type("mbed"); T.key("return")
    T.check(v.panel and v.panel.state == "confirm" and v.panel.platform.deprecated, "deprecated family can still be installed")
    T.no_errors()
  end,
}
