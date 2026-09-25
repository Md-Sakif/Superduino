--! FAKE_CLI_ON_PATH=0
-- Without arduino-cli the welcome screen says so; locating it by path works.
return {
  run = function(T)
    local core = require "core"
    local config = require "core.config"
    local cli = require "plugins.arduino.cli"
    T.wait_until(function() return cli.status ~= "checking" end, 10, "arduino-cli check")
    T.eq(cli.status, "not_found", "reported as not installed")
    local ev = core.active_view
    T.wait_until(function() return ev.items and #ev.items > 0 end, 3, "welcome rows")
    local labels = {}
    for _, item in ipairs(ev.items) do labels[item.label] = true end
    T.check(labels["Not installed"], "welcome shows Not installed")
    T.check(labels["Download arduino-cli for Me"], "welcome offers to download arduino-cli")
    T.check(labels["Locate My Own arduino-cli..."], "welcome offers Locate")
    T.check(labels["Installation Guide"], "welcome offers the installation guide")

    config.use_system_file_picker = false
    T.command("arduino:locate-cli")
    T.wait(0.1)
    core.command_view:set_text(T.fixtures .. "/bin/arduino-cli")
    T.command("command:submit")
    T.wait_until(function() return cli.status == "ok" end, 10, "located arduino-cli to work")
    T.eq(cli.path, T.fixtures .. "/bin/arduino-cli", "uses the located file")
  end,
}
