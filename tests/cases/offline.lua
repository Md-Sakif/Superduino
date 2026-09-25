-- Offline: clear messages when the board list cannot be refreshed or a download fails.
return {
  before = function(T)
    T.mkdir(T.home .. "/Arduino")
    T.fake_cli({ offline = true })
    -- an old board index
    T.mkdir(T.home .. "/.arduino15")
    T.write_file(T.home .. "/.arduino15/package_index.json", "{}")
    local proc = process.start({ "touch", "-d", "3 days ago", T.home .. "/.arduino15/package_index.json" })
    proc:wait(5)
  end,
  run = function(T)
    local v = T.open_wizard()
    T.wait_until(function() return v.index.state ~= "updating" and v.index.state ~= "idle" end, 10, "index refresh")
    T.eq(v.index.state, "offline", "recognized as offline")
    local status = v:index_status()
    T.match(status, "Offline: using the board list from 3 days ago", "says which board list is used")
    T.key("return")
    T.type("samd"); T.key("return"); T.key("return")
    T.wait_until(function() return v.panel and v.panel.state == "failed" end, 10, "the install to fail")
    local explanation = require("plugins.arduino.cli").explain_error(v.panel.error .. "\n" .. (v.panel.details or ""))
    T.eq(explanation, "Could not connect to the internet. Check your connection and try again.", "plain explanation")
    T.match(v.panel.details or v.panel.error, "no such host", "technical details are kept")
    T.eq(#require("plugins.arduino.project").incomplete_installs(), 0, "a failed download leaves nothing half installed")
    T.shot("offline-install")
  end,
}
