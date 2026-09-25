--! FAKE_CLI_ON_PATH=0
-- An executable that does not report a version is shown as not working.
return {
  before = function(T)
    local path = T.dir .. "/broken-cli"
    T.write_file(path, "#!/bin/sh\necho 'Error: something is wrong' >&2\nexit 1\n")
    local proc = process.start({ "chmod", "+x", path })
    proc:wait(5)
    require("core.storage").save("arduino", "cli", { path = path })
  end,
  run = function(T)
    local cli = require "plugins.arduino.cli"
    T.wait_until(function() return cli.status ~= "checking" end, 10, "arduino-cli check")
    T.eq(cli.status, "broken", "reported as not working")
    T.match(cli.error, "something is wrong", "the error message is kept")
  end,
}
