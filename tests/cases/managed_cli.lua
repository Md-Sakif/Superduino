--! FAKE_CLI_ON_PATH=0
-- "Download arduino-cli for me": latest version, checksum verified, license kept, used right away.
return {
  before = function(T)
    -- a local "release": archive with the fake arduino-cli, and its checksums
    local rel = T.dir .. "/release"
    T.mkdir(rel .. "/pack")
    local cmd = table.concat({
      "cp '" .. T.fixtures .. "/bin/arduino-cli' '" .. rel .. "/pack/arduino-cli'",
      "echo 'GPLv3 text' > '" .. rel .. "/pack/LICENSE.txt'",
      "tar -czf '" .. rel .. "/arduino-cli_9.9.9_Linux_64bit.tar.gz' -C '" .. rel .. "/pack' arduino-cli LICENSE.txt",
      "mkdir -p '" .. rel .. "/v9.9.9'",
      "cd '" .. rel .. "' && sha256sum arduino-cli_9.9.9_Linux_64bit.tar.gz > v9.9.9/9.9.9-checksums.txt",
    }, " && ")
    local proc = process.start({ "sh", "-c", cmd })
    proc:wait(10)
    local managed = require "plugins.arduino.managed_cli"
    managed.DOWNLOAD_BASE = "file://" .. rel
    managed.RELEASE_BASE = "file://" .. rel
    function managed.latest_version() return "9.9.9" end
  end,
  run = function(T)
    local cli = require "plugins.arduino.cli"
    local managed = require "plugins.arduino.managed_cli"
    T.wait_until(function() return cli.status == "not_found" end, 10, "no arduino-cli")
    T.command("arduino:download-cli")
    T.wait_until(function() return cli.status == "ok" and cli.managed end, 20, "the managed arduino-cli to work")
    T.eq(cli.path, T.home .. "/.local/share/superduino/arduino-cli/arduino-cli", "installed in Superduino's folder")
    T.check(system.get_file_info(T.home .. "/.local/share/superduino/arduino-cli/LICENSE.txt") ~= nil,
      "arduino-cli's license is kept next to it")
    local saved = require("core.storage").load("arduino", "cli")
    T.check(saved and saved.managed, "remembered as managed")

    -- a download that does not match its checksum is refused
    T.write_file(T.dir .. "/release/v9.9.9/9.9.9-checksums.txt",
      string.rep("0", 64) .. "  arduino-cli_9.9.9_Linux_64bit.tar.gz\n")
    T.command("arduino:download-cli")
    T.wait_until(function() return managed.status.state == "failed" end, 20, "checksum failure")
    T.match(managed.status.error, "did not match its published checksum", "explains the checksum failure")
    T.eq(cli.status, "ok", "the working copy is kept")
  end,
}
