-- A family that is not installed can be installed from the wizard, with progress.
return {
  before = function(T) T.mkdir(T.home .. "/Arduino") end,
  run = function(T)
    local v = T.open_wizard()
    T.key("return")
    T.type("samd")
    T.eq(T.selected(v), "Arduino SAMD Boards (32-bits ARM Cortex-M0+)", "SAMD found")
    T.eq(v:get_list()[v.selected].installed, false, "marked as not installed")
    T.key("return")
    T.eq(v.panel and v.panel.state, "confirm", "asks before downloading")
    -- sizes from package_index.json: platform 2.92 MB + tool 95.23 MB for this computer;
    -- serial-discovery is already installed and not counted
    local panel = v.panel
    local size = T.wait_until(function() return panel.size end, 10, "the download size")
    T.eq(size and size.download, 98150000, "download size of the platform and its tools")
    T.eq(size and require("plugins.arduino.install_size").describe(size),
      "Downloads about 98 MB and needs about 491 MB of disk space.", "size is explained")
    T.key("backspace")
    T.eq(v.panel and v.panel.state, "confirm", "Backspace does not dismiss the question")
    T.key("escape")
    T.eq(v.panel, nil, "Esc means not now")
    T.key("return")
    local progress_seen = false
    T.key("return")
    T.eq(v.panel and v.panel.state, "running", "installing")
    T.key("escape"); T.key("backspace")
    T.eq(v.panel and v.panel.state, "running", "Esc and Backspace do not stop a running install")
    T.wait_until(function()
      if v.panel and v.panel.progress then progress_seen = true end
      return v.panel == nil
    end, 20, "the install to finish")
    T.check(progress_seen, "download progress was reported")
    T.eq(v.step, 3, "moves on to the board step")
    T.eq(T.selected(v), "Arduino MKR WiFi 1010", "lists the new boards")
    T.match(v.message or "", "Installed Arduino SAMD", "says it was installed")
    T.no_errors()
  end,
}
