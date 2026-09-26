-- sketch.yaml edits change only what they must: other profiles, libraries,
-- comments, quoting and line endings are kept.
return {
  run = function(T)
    local sketch_yaml = require "plugins.arduino.sketch_yaml"
    local text = table.concat({
      "# my notes",
      "profiles:",
      "  uno:",
      "    fqbn: \"arduino:avr:uno\"   # the board",
      "    platforms:",
      "      - platform: arduino:avr (1.8.6)",
      "    libraries:",
      "      - Servo (1.3.0)",
      "",
      "  bare:",
      "    notes: no fqbn, no platforms",
      "",
      "default_profile: 'uno'",
      "",
    }, "\r\n")
    local file = sketch_yaml.parse(text)
    T.eq(#file.profiles, 2, "two profiles")
    T.eq(file.default_name, "uno", "quoted default profile")
    local uno = sketch_yaml.default_profile(file)
    T.eq(uno.fqbn, "arduino:avr:uno", "quoted fqbn with a comment")
    T.eq(table.concat(sketch_yaml.platform_lines(file, uno), "|"),
      "    platforms:|      - platform: arduino:avr (1.8.6)", "platforms list ends before libraries")

    -- only the fqbn changes
    local out = sketch_yaml.update(file, "uno", { fqbn = "arduino:avr:uno:x=y" })
    T.eq(out, (text:gsub('"arduino:avr:uno"   # the board', "arduino:avr:uno:x=y")), "one line changed, CRLF kept")

    -- another family: new platforms list (re-indented), renamed profile and default
    out = sketch_yaml.update(file, "uno", { fqbn = "esp32:esp32:esp32", rename = "esp32", platform_lines = {
      "  platforms:", "    - platform: esp32:esp32 (3.3.11)", "      platform_index_url: https://x/y.json" } })
    local expected = table.concat({
      "# my notes", "profiles:", "  esp32:", "    fqbn: esp32:esp32:esp32", "    platforms:",
      "      - platform: esp32:esp32 (3.3.11)", "        platform_index_url: https://x/y.json",
      "    libraries:", "      - Servo (1.3.0)", "", "  bare:", "    notes: no fqbn, no platforms", "",
      "default_profile: esp32", "" }, "\r\n")
    T.eq(out, expected, "platforms replaced, libraries and other profiles kept")

    -- a profile without fqbn and platforms gets both, fqbn first
    out = sketch_yaml.update(file, "bare", { fqbn = "arduino:avr:nano", platform_lines = {
      "    platforms:", "      - platform: arduino:avr (1.8.8)" } })
    T.match(out, "  bare:\r\n    fqbn: arduino:avr:nano\r\n    platforms:\r\n      %- platform: arduino:avr %(1%.8%.8%)\r\n"
      .. "    notes: no fqbn", "fqbn and platforms added under the header")
    T.match(out, "default_profile: 'uno'", "default of another profile is untouched")
  end,
}
