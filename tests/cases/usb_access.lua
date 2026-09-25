-- Serial port group and board setup scripts, with a fake pkexec.
return {
  before = function(T)
    -- an installed family that ships a setup script
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8", ["arduino:renesas_uno"] = "1.6.0" } })
    local dir = T.home .. "/.arduino15/packages/arduino/hardware/renesas_uno/1.6.0"
    T.mkdir(dir)
    T.write_file(dir .. "/post_install.sh", "#!/usr/bin/env bash\necho rules\n")
  end,
  run = function(T)
    local core = require "core"
    local access = require "plugins.arduino.access"
    T.fake_pkexec("ok")
    T.wait_until(function() return access.serial.state ~= "checking" end, 10, "serial check")
    T.check(({ ok = true, missing = true, relogin = true, unknown = true })[access.serial.state],
      "serial state is known: " .. access.serial.state)
    T.wait_until(function() return #access.pending_setups == 1 end, 10, "pending setup to be found")
    local setup = access.pending_setups[1]
    T.eq(setup.id, "arduino:renesas_uno", "setup script of UNO R4 found")

    -- welcome screen lists it
    local ev = core.active_view
    local found = false
    for _, item in ipairs(ev.items or {}) do
      if item.label:find("Set up Arduino UNO R4 Boards", 1, true) then found = true end
    end
    T.check(found, "welcome screen offers the setup")

    -- serial fix command (with a pretend status, since the real one depends on the machine)
    access.serial = { state = "missing", group = "dialout", user = "someone" }
    T.match(table.concat(access.serial_fix_command(), " "), "usermod %-aG dialout someone$", "fix adds the user to the group")

    local result
    T.fake_pkexec("cancel")
    core.add_thread(function() result = access.run_setup(setup) end)
    T.wait_until(function() return result end, 10, "cancelled setup")
    T.eq(result, "cancelled", "closing the password dialog is reported as cancelled")
    T.eq(#access.pending_setups, 1, "still pending after cancel")

    result = nil
    T.fake_pkexec("fail")
    core.add_thread(function() result = access.run_setup(setup) end)
    T.wait_until(function() return result end, 10, "failed setup")
    T.eq(result, "failed", "a failing script is reported")

    result = nil
    T.fake_pkexec("ok")
    core.add_thread(function() result = access.run_setup(setup) end)
    T.wait_until(function() return result end, 10, "successful setup")
    T.eq(result, "ok", "setup succeeds")
    T.eq(#access.pending_setups, 0, "no longer pending")
    T.eq(access.setup_record("arduino:renesas_uno", "1.6.0"), "done", "remembered as done")
    T.match(T.pkexec_calls(), "/bin/bash .*renesas_uno/1.6.0/post_install.sh", "the script was run through pkexec")

    access.ADMIN_COMMAND = "/nonexistent/pkexec"
    result = nil
    core.add_thread(function() result = access.run_as_admin({ "/bin/true" }) end)
    T.wait_until(function() return result end, 5, "no pkexec")
    T.eq(result, "unavailable", "missing pkexec is detected")
    T.eq(access.terminal_command({ "/bin/bash", "/a b/post_install.sh" }), "sudo /bin/bash '/a b/post_install.sh'",
      "terminal command is quoted")
  end,
}
