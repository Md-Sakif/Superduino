-- The Build section of the left pane builds and uploads the open sketch, follows
-- connected ports, and the Output panel shows the output with clickable errors.
local SKETCH = "void setup() {\n}\n\nvoid loop() {\n}\n"

return {
  before = function(T)
    T.fake_cli({ installed = { ["arduino:avr"] = "1.8.8" }, ports = T.array() })
  end,
  run = function(T)
    local core = require "core"
    local dir = T.home .. "/Arduino/Blink"
    local ino = dir .. "/Blink.ino"
    if T.phase == 1 then
      T.mkdir(dir)
      local fp = io.open(ino, "w"); fp:write(SKETCH); fp:close()
      fp = io.open(dir .. "/sketch.yaml", "w")
      fp:write("profiles:\n  uno:\n    fqbn: arduino:avr:uno\n    platforms:\n      - platform: arduino:avr (1.8.8)\n\n"
        .. "default_profile: uno\n")
      fp:close()
      T.expect_restart()
      core.open_project(dir)
      return
    end

    local build = require "plugins.arduino.build"
    local ports = require "plugins.arduino.ports"
    local BuildPanel = require "plugins.arduino.build_panel"
    local BoardPanel = require "plugins.arduino.board_panel"
    local OutputView = require "plugins.arduino.output_view"
    local treeview = require "plugins.treeview"
    local panel = BuildPanel.view
    local function click(id)
      local L = panel.current_layout
      for _, target in ipairs(L and L.targets or {}) do
        if target.id == id then
          panel:on_mouse_pressed("left", target.x + 2, panel.position.y + target.y + 2, 1)
          return true
        end
      end
      T.check(false, "the Build section has " .. id)
    end
    local function finished(what)
      return T.wait_until(function() return build.last and build.last.state ~= "running" end, 15, what)
    end
    local function status() return panel:status(BuildPanel.sketch()) end
    local function output_text()
      local lines = {}
      for _, line in ipairs(build.last.lines) do table.insert(lines, line.text) end
      return table.concat(lines, "\n")
    end

    -- placement: file tree, then Build, then Board
    T.check(panel ~= nil, "the Build section was added")
    T.wait_until(function() return panel.size.y > 0 and BoardPanel.view.size.y > 0 end, 5, "both sections")
    T.check(treeview.position.y < panel.position.y and panel.position.y < BoardPanel.view.position.y,
      "Build is under the file tree and over the Board section")
    T.eq(panel.position.x, treeview.position.x, "in the left pane")
    T.wait_until(function() return ports.state == "watching" end, 5, "ports to be followed")
    T.eq(BuildPanel.sketch().port, nil, "no board connected yet")

    -- Build
    click("build:build")
    T.eq(build.last and build.last.kind, "build", "Build starts a build")
    T.check(OutputView.view and OutputView.view.visible, "the Output panel opens")
    finished("the build")
    T.eq(build.last.state, "done", "the build succeeds")
    T.eq(status(), "Build done", "the section says the build is done")
    T.eq(select(3, status()), "Flash 2%  ·  RAM 0%", "and shows the memory use")
    T.match(output_text(), "Sketch uses 924 bytes", "the output has arduino-cli's summary")
    T.match(T.fake_cli_calls(), "compile %-%-no%-color " .. dir:gsub("%p", "%%%0"), "arduino-cli compiles the sketch folder")

    -- a board is plugged in: it is followed and chosen, as it matches the sketch's board
    T.fake_cli_set("ports", { { address = "/dev/ttyUSB0", boards = { { "Arduino UNO", "arduino:avr:uno" } } } })
    T.wait_until(function() return BuildPanel.sketch().port end, 5, "the plugged-in board")
    T.eq(BuildPanel.sketch().port.address, "/dev/ttyUSB0", "its port is used")
    T.shot("build-done")

    -- Upload (Ctrl+U)
    T.key("ctrl+u")
    finished("the upload")
    T.eq(build.last.kind, "upload", "Ctrl+U uploads")
    T.eq(build.last.state, "done", "the upload succeeds")
    T.match(T.fake_cli_calls(), "%-%-upload %-p /dev/ttyUSB0", "to the port")
    T.eq(status(), "Uploaded to /dev/ttyUSB0", "the section says where it was uploaded")
    T.match(output_text(), "Writing | #+ | 100%%", "the upload progress is kept at its last state")

    -- an error: unsaved edits are saved first; the error opens the file at its line
    local dv = core.root_view:open_doc(core.open_doc(ino))
    dv.doc:insert(2, 1, "  foo(); // ERROR_HERE\n")
    T.key("ctrl+b")
    finished("the failing build")
    T.check(not dv.doc:is_dirty(), "the sketch was saved before building")
    T.eq(build.last.state, "failed", "the build fails")
    T.eq(build.last.errors, 1, "one error")
    T.eq(status(), "Build failed: 1 error", "the section says why")
    local error_line
    for _, line in ipairs(build.last.lines) do
      if line.kind == "error" and line.file then error_line = line end
    end
    T.eq(error_line and error_line.file, ino, "the error names the sketch file")
    T.eq(error_line and error_line.line, 2, "and the line")
    T.shot("build-error")
    core.set_active_view(treeview)
    OutputView.view:open_line(error_line)
    T.eq(core.active_view.doc and core.active_view.doc.abs_filename, ino, "clicking the error opens the file")
    T.eq(select(1, core.active_view.doc:get_selection()), 2, "at the error's line")

    -- permission denied: a hint that fixes it
    dv.doc:remove(2, 1, 3, 1)
    T.fake_cli_set("upload_denied", true)
    T.key("ctrl+u")
    finished("the denied upload")
    T.eq(build.last.state, "failed", "the upload fails")
    local hint
    for _, line in ipairs(build.last.lines) do if line.kind == "hint" then hint = line end end
    T.eq(hint and hint.command, "arduino:allow-serial-port-access", "a hint offers to allow serial port access")
    T.fake_cli_set("upload_denied", false)

    -- two other boards: none matches, so the port is chosen by the user and remembered
    T.fake_cli_set("ports", { { address = "/dev/ttyACM0" }, { address = "/dev/ttyUSB5" } })
    T.wait_until(function() return #ports.list == 2 end, 5, "the new ports")
    T.eq(BuildPanel.sketch().port, nil, "no port is guessed")
    click("build:port")
    T.eq(core.active_view, core.command_view, "clicking the port asks for one")
    T.type("ttyUSB5")
    T.wait_until(function() return #core.command_view.suggestions == 1 end, 5, "the list to follow the typed text")
    T.key("return")
    T.eq(BuildPanel.sketch().port and BuildPanel.sketch().port.address, "/dev/ttyUSB5", "the chosen port is used")
    T.eq(ports.saved(dir), "/dev/ttyUSB5", "and remembered for the sketch")

    -- cancel a long build
    T.fake_cli_set("compile_slow", true)
    click("build:build")
    T.wait_until(function() return panel.current_layout.buttons[1].id == "build:cancel" end, 5, "the Cancel button")
    click("build:cancel")
    finished("the cancelled build")
    T.eq(build.last.state, "cancelled", "the build is cancelled")
    T.eq(status(), "Build cancelled", "the section says so")

    -- the Output panel hides
    local hide
    for _, link in ipairs(OutputView.view.links) do if link.id == "output:hide" then hide = link end end
    OutputView.view:on_mouse_pressed("left", hide.x + 2, hide.y + 2, 1)
    T.eq(OutputView.view.visible, false, "Hide hides the Output panel")
    T.no_errors()
  end,
}
