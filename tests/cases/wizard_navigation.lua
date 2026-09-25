-- Going back with Backspace, Esc and breadcrumbs keeps choices; filtering ranks well.
return {
  before = function(T) T.mkdir(T.home .. "/Arduino") end,
  run = function(T)
    local v = T.open_wizard()
    T.key("return"); T.key("return")
    T.eq(v.step, 3, "at the board step")
    T.type("nano")
    T.eq(T.selected(v), "Arduino Nano", "nano selects Arduino Nano")
    T.eq(#v:get_list(), 1, "no fuzzy noise next to a real match")
    for _ = 1, 4 do T.key("backspace") end
    T.eq(v.filter, "", "backspace clears the search")
    T.key("backspace")
    T.eq(v.step, 2, "backspace on an empty search goes back")
    T.key("return")
    T.type("mega"); T.key("return")
    T.eq(v.choice[3], "arduino:avr:mega", "board chosen")
    local crumb = v.current_layout.crumbs[1]
    v:on_mouse_pressed("left", crumb.x + 2, crumb.y + 2, 1)
    T.eq(v.step, 1, "clicking the first breadcrumb goes to the vendor step")
    T.key("return"); T.key("return")
    T.eq(T.selected(v), "Arduino Mega or Mega 2560", "earlier board choice is kept")
    T.key("escape")
    T.eq(v.step, 2, "escape goes back")
    T.key("down")
    T.no_errors()
  end,
}
