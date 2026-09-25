--! FAKE_CLI_ON_PATH=0
-- A remembered location that no longer exists is reported, not silently replaced.
return {
  before = function(T)
    require("core.storage").save("arduino", "cli", { path = T.dir .. "/gone/arduino-cli" })
  end,
  run = function(T)
    local cli = require "plugins.arduino.cli"
    T.wait_until(function() return cli.status ~= "checking" end, 10, "arduino-cli check")
    T.eq(cli.status, "missing", "reported as missing")
    T.eq(cli.path, T.dir .. "/gone/arduino-cli", "keeps the remembered path")
    local warned = false
    for _, text in ipairs(T.problems()) do if text:find("not found at", 1, true) then warned = true end end
    T.check(warned, "a warning is logged")
  end,
}
