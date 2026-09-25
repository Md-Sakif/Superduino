-- A fresh arduino-cli without a board index still gets a board list.
return {
  before = function(T) T.fake_cli({ has_index = false, installed = {} }) end,
  run = function(T)
    local v = T.open_wizard()
    T.check(v.load_error == nil, "the board list loads")
    T.eq(T.selected(v), "Arduino", "vendors are listed")
    T.key("return")
    T.eq(v:get_list()[v.selected].installed, false, "nothing installed yet")
    T.no_errors()
  end,
}
