-- First run: arduino-cli on PATH is found, checked and remembered.
return {
  run = function(T)
    local cli = require "plugins.arduino.cli"
    local storage = require "core.storage"
    T.wait_until(function() return cli.status ~= "checking" end, 10, "arduino-cli check")
    T.eq(cli.status, "ok", "arduino-cli is usable")
    T.eq(cli.version, "1.5.1", "version is read from `version --json`")
    T.match(cli.path, "tests/fixtures/bin/arduino%-cli$", "found on PATH")
    local saved = storage.load("arduino", "cli")
    T.eq(saved and saved.path, cli.path, "location is remembered")
    T.no_errors()
  end,
}
