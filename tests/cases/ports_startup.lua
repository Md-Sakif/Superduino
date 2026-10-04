-- A board plugged in before Superduino starts is found even when the port
-- watch does not report it, and a watch that reports nothing is backed up by
-- listing the ports from time to time.
return {
  before = function(T)
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8" }, watch_misses_initial = true,
      ports = { { address = "/dev/ttyUSB0" } } })
  end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    if T.phase == 1 then
      T.mkdir(dir)
      T.write_file(dir .. "/Blink.ino", "void setup() {}\nvoid loop() {}\n")
      T.write_file(dir .. "/sketch.yaml", "profiles:\n  uno:\n    fqbn: arduino:avr:uno\n    platforms:\n"
        .. "      - platform: arduino:avr (1.8.8)\n\ndefault_profile: uno\n")
      T.expect_restart()
      core.open_project(dir)
      return
    end
    local ports = require "plugins.arduino.ports"
    local BuildPanel = require "plugins.arduino.build_panel"
    ports.RELIST_INTERVAL = 1

    -- the watch misses the board that was already plugged in; listing finds it
    local port = T.wait_until(function() return BuildPanel.sketch().port end, 10, "the plugged-in board")
    T.eq(port and port.address, "/dev/ttyUSB0", "the board plugged in before the start is found")
    T.eq(ports.state, "watching", "while the watch keeps running")
    T.match(T.fake_cli_calls(), "\nboard list %-%-json", "by listing the ports once")

    -- a watch that reports nothing: unplugged and plugged in again, found by listing again
    T.fake_cli_set("watch_silent", true)
    T.fake_cli_set("ports", T.array())
    -- (only a listing or an event can tell that it is gone; take it out as an event would)
    ports.apply_event({ eventType = "remove", port = { address = "/dev/ttyUSB0", protocol = "serial" } })
    T.eq(BuildPanel.sketch().port, nil, "no board")
    T.fake_cli_set("ports", { { address = "/dev/ttyUSB1" } })
    port = T.wait_until(function() return BuildPanel.sketch().port end, 10, "the board found by listing again")
    T.eq(port and port.address, "/dev/ttyUSB1", "listing again finds it while none is known")
    T.no_errors()
  end,
}
