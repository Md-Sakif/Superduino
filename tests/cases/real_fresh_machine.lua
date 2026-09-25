--! FAKE_CLI_ON_PATH=0
--! TIMEOUT=600
-- Uses the network: SUPERDUINO_REAL_TESTS=1 tests/run.sh real
-- A brand-new machine: Superduino downloads the real arduino-cli, then the
-- wizard loads the real board list (arduino-cli fetches its index and tools).
return {
  run = function(T)
    if os.getenv("SUPERDUINO_REAL_TESTS") ~= "1" then
      T.check(true, "skipped: set SUPERDUINO_REAL_TESTS=1 to run")
      return
    end
    local core = require "core"
    local cli = require "plugins.arduino.cli"
    local managed = require "plugins.arduino.managed_cli"
    T.wait_until(function() return cli.status == "not_found" end, 10, "no arduino-cli")
    T.command("arduino:download-cli")
    local version = T.wait_until(function() return managed.status.version end, 60, "the latest version")
    T.log("latest arduino-cli: %s", tostring(version))
    T.match(version or "", "^%d+%.%d+%.%d+$", "latest version is a stable release")
    T.wait_until(function() return cli.status == "ok" or managed.status.state == "failed" end, 300, "download")
    T.eq(managed.status.state, "idle", "download succeeded: " .. tostring(managed.status.error) .. " " .. tostring(managed.status.details))
    T.eq(cli.status, "ok", "the downloaded arduino-cli works")
    T.eq(cli.version, version, "and reports the downloaded version")

    T.command("arduino:new-project")
    local v = T.wait_until(function()
      local view = core.active_view
      return tostring(view) == "NewProjectView" and not view.loading and view
    end, 400, "the real board list (first run downloads arduino-cli's tools)")
    T.check(v and not v.load_error, "the board list loaded: " .. tostring(v and v.load_error))
    T.eq(v and T.selected(v), "Arduino", "Arduino vendor listed")
    T.wait_until(function() return v.index.state ~= "updating" end, 120, "index refresh")
    T.eq(v.index.state, "updated", "board list refreshed online")
    T.key("return")
    T.check(#v:get_list() > 10, "many Arduino families listed: " .. #v:get_list())
  end,
}
