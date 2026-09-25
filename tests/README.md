# Superduino testbench

End-to-end tests that start the real editor and drive it like a user would
(keys, typing, clicks, commands), then check what happened.

```sh
tests/run.sh              # run everything
tests/run.sh wizard       # only cases whose name contains "wizard"
tests/run.sh --visible    # show the windows and save T.shot() screenshots
tests/run.sh --keep       # keep the temporary folder (kept anyway on failure)
```

Requirements: a built tree (`meson setup build`), `python3`, `bc`; for
`--visible` screenshots also `xdotool` and ImageMagick's `import`.

## Isolation

Each case runs in a fresh temporary folder with its own `HOME`, user
directory and `PATH`, so your real settings, sketchbook and `~/.arduino15`
are never touched. By default the editor uses SDL's offscreen video driver,
so no windows appear.

- `tests/fixtures/bin/arduino-cli` is a stand-in arduino-cli (Python) that
  mimics the real JSON and progress output. A case describes its scenario
  with `T.fake_cli{...}` in `before` (installed platforms, offline mode,
  failing or slow installs, extra board index URLs...). See `DEFAULT_STATE`
  in that file.
- `tests/fixtures/fake-pkexec` stands in for the administrator password
  dialog; `T.fake_pkexec("ok" | "cancel" | "fail")` selects its behaviour.

## Writing a case

A case is `tests/cases/<name>.lua` returning:

```lua
--! TIMEOUT=60            -- optional runner settings
--! FAKE_CLI_ON_PATH=0    -- e.g. to simulate a machine without arduino-cli
return {
  before = function(T) ... end, -- optional, runs before plugins load
  run = function(T) ... end,    -- runs once the editor is up
}
```

Useful helpers (see `tests/harness.lua`): `T.check`, `T.eq`, `T.match`,
`T.wait_until`, `T.key`, `T.type`, `T.command`, `T.open_wizard`,
`T.selected`, `T.no_errors`, `T.mkdir`, `T.read_file`, `T.shot`.

Cases named `real_*` use the network and the real arduino-cli (for example
downloading it the way "Download arduino-cli for Me" does). They are skipped
unless you run `SUPERDUINO_REAL_TESTS=1 tests/run.sh real`.

A case that restarts the editor (opening a project does) calls
`T.expect_restart()` first; `run` is called again afterwards with
`T.phase` increased by one.

Add a case for every feature and every bug fix, and run the whole suite
before committing.
