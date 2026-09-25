-- Cancelling a download is harmless; cancelling while files are unpacked needs a
-- confirmation, leaves the family half installed, and it can be repaired.
return {
  before = function(T)
    T.mkdir(T.home .. "/Arduino")
    T.fake_cli({ install_slow = "esp32:esp32" })
  end,
  run = function(T)
    local project = require "plugins.arduino.project"
    local v = T.open_wizard()
    T.type("esp"); T.key("return")
    T.eq(v.choice[1], "esp32", "Espressif chosen")

    -- cancel while downloading: nothing is broken
    T.key("return"); T.key("return")
    T.wait_until(function() return v.panel and v.panel.progress end, 10, "download progress")
    v.panel:cancel()
    T.wait_until(function() return v.panel == nil end, 10, "cancelled download")
    T.match(v.message or "", "cancelled", "says it was cancelled")
    T.eq(#project.incomplete_installs(), 0, "a cancelled download leaves nothing half installed")

    -- cancel while unpacking: warned first
    T.key("return"); T.key("return")
    T.wait_until(function() return v.panel and v.panel.handle and v.panel.handle.phase == "install" end, 10, "install phase")
    v.panel:cancel()
    T.eq(v.panel.state, "confirm-cancel", "stopping while unpacking asks first")
    T.key("escape")
    T.eq(v.panel.state, "running", "Esc keeps installing")
    v.panel:cancel()
    T.shot("confirm-cancel")
    v.panel:buttons().back.run() -- Stop Anyway
    T.wait_until(function() return v.panel and v.panel.state == "incomplete" end, 10, "half installed state")
    T.eq(#project.incomplete_installs(), 1, "recorded as half installed")
    T.shot("incomplete")

    -- repair later: the family is marked in the list
    T.key("escape")
    T.eq(v.panel, nil, "Repair Later closes the panel")
    T.match(v.message or "", "half installed", "reminds that it is half installed")
    T.eq(v:get_list()[v.selected].detail, "half installed - needs repair", "marked in the family list")

    -- repair now
    T.fake_cli_set("install_slow", false)
    T.key("return")
    T.eq(v.panel and v.panel.mode, "repair", "choosing it again offers repair")
    T.key("return")
    T.wait_until(function() return v.panel == nil end, 20, "repair to finish")
    T.eq(v.step, 3, "moves on to the board step after repair")
    T.eq(#project.incomplete_installs(), 0, "no longer half installed")
    T.match(T.fake_cli_calls(), "core uninstall esp32:esp32", "repair removed the broken install first")
  end,
}
