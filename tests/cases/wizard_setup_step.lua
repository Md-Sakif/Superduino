-- After installing a family with a setup script, the wizard offers USB setup.
return {
  before = function(T) T.mkdir(T.home .. "/Arduino") end,
  run = function(T)
    T.fake_pkexec("cancel")
    local v = T.open_wizard()
    T.key("return")
    T.type("r4"); T.key("return")
    T.eq(v.panel and v.panel.state, "confirm", "UNO R4 needs installing")
    T.key("return")
    T.wait_until(function() return v.panel and v.panel.state == "setup" end, 20, "the setup step")
    v.panel:toggle_script()
    T.check(v.panel.script_lines and #v.panel.script_lines > 0, "Show Script shows the script")
    T.shot("setup-step")
    T.key("return")
    T.wait_until(function() return v.panel and v.panel.state == "setup" and v.panel.setup_note end, 10, "cancelled dialog")
    T.match(v.panel.setup_note, "password dialog was closed", "explains the closed dialog")
    T.fake_pkexec("ok")
    T.key("return")
    T.wait_until(function() return v.panel == nil end, 10, "setup to finish")
    T.eq(v.step, 3, "moves on to the board step")
    T.match(v.message or "", "set up USB access", "says USB access was set up")
    T.eq(T.selected(v), "Arduino UNO R4 Minima", "lists the new boards")
  end,
}
