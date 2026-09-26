-- Panel of the New Project page that installs (or repairs) a board platform,
-- then offers its USB setup script when it has one.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local EmptyView = require "core.emptyview"
local cli = require "plugins.arduino.cli"
local project = require "plugins.arduino.project"
local access = require "plugins.arduino.access"
local ui = require "plugins.arduino.ui"

local InstallPanel = {}
InstallPanel.__index = InstallPanel

-- "Arduino UNO, Arduino Nano and 25 more"
local function examples(names)
  if not names or #names == 0 then return nil end
  local shown = {}
  for i = 1, math.min(3, #names) do shown[i] = names[i] end
  local text = table.concat(shown, ", ")
  if #names > 3 then text = text .. " and " .. (#names - 3) .. " more" end
  return text
end
InstallPanel.examples = examples


---@param view table The New Project page.
---@param platform table Family { id, name, vendor_name, board_names, platform? }.
---@param mode "install"|"repair"
function InstallPanel.new(view, platform, mode)
  local panel = setmetatable({ view = view, platform = platform, mode = mode or "install" }, InstallPanel)
  panel.state = panel.mode == "repair" and "incomplete" or "confirm"
  return panel
end


function InstallPanel:set_state(state)
  self.state = state
  core.redraw = true
end


-------------------------------------------------------------------------------
-- Installing
-------------------------------------------------------------------------------

function InstallPanel:start()
  local repair = self.mode == "repair" or self.state == "incomplete"
  self.error, self.details, self.note = nil, nil, nil
  self.handle = { name = self.platform.name }
  self.progress, self.done, self.current = nil, {}, "Starting..."
  self:set_state("running")
  self.view.message = nil
  core.add_thread(function()
    local run = repair and project.repair_platform or project.install_platform
    local ok, err = run(self.platform.id, self.handle, function(event)
      if event.kind == "progress" then
        self.progress, self.current = event, "Downloading " .. event.item
      elseif event.kind == "downloaded" then
        self.progress = nil
        table.insert(self.done, "Downloaded " .. event.item)
      elseif event.kind == "installing" then
        self.progress, self.current = nil, "Installing " .. event.item
      elseif event.kind == "installed" then
        table.insert(self.done, "Installed " .. event.item)
      elseif event.kind == "message" then
        self.current = event.text
      end
      core.redraw = true
    end)
    if self.view.panel ~= self then return end
    if ok then
      self:installed()
    elseif err == "cancelled" then
      if self.handle.phase == "install" then
        self.note = "The installation was stopped while files were being unpacked."
        self:set_state("incomplete")
      else
        self.view:close_panel("Installation of " .. self.platform.name .. " was cancelled.")
      end
    elseif self.handle.phase == "install" then
      self.note = "The installation failed while files were being unpacked."
      self.error, self.details = err, self.handle.details
      self:set_state("incomplete")
    else
      self.error, self.details = err, self.handle.details
      self:set_state("failed")
    end
  end)
end


-- Called in the install thread once arduino-cli reports success.
function InstallPanel:installed()
  self.current = "Loading the new boards..."
  core.redraw = true
  project.forget_cache()
  local loaded, load_err = self.view:load_data()
  if not loaded then
    self.view:close_panel(load_err, true)
    return
  end
  core.log("%s %s", self.mode == "repair" and "Repaired" or "Installed", self.platform.name)
  -- some families ship a script that installs USB permission rules (Linux only)
  local version
  for _, board in ipairs(self.view.boards) do
    if board.arch == self.platform.id then version = board.version break end
  end
  local script = version and access.setup_script(self.platform.id, version)
  if script and access.setup_record(self.platform.id, version) ~= "done" then
    self.setup = { id = self.platform.id, name = self.platform.name, version = version, script = script }
    self:set_state("setup")
    return
  end
  self.view:finish_install(self.platform.id, (self.mode == "repair" and "Repaired " or "Installed ")
    .. self.platform.name .. ". Now choose your board.")
end


function InstallPanel:cancel()
  if self.state ~= "running" then return end
  if self.handle.phase == "install" then
    -- files are being unpacked: stopping now breaks the installation
    self:set_state("confirm-cancel")
  else
    self:stop()
  end
end


function InstallPanel:stop()
  self.handle.cancelled = true
  self.current = "Stopping..."
  self:set_state("running")
end


-------------------------------------------------------------------------------
-- USB setup script
-------------------------------------------------------------------------------

function InstallPanel:start_setup()
  self.setup_output = nil
  self:set_state("setup-running")
  core.add_thread(function()
    local result, output = access.run_setup(self.setup)
    if self.view.panel ~= self then return end
    if result == "ok" then
      self.view:finish_install(self.platform.id, "Installed " .. self.platform.name
        .. " and set up USB access. Now choose your board.")
    elseif result == "cancelled" then
      self.setup_note = "The password dialog was closed. You can try again, or skip and do it later from the welcome screen."
      self:set_state("setup")
    elseif result == "unavailable" then
      self:set_state("setup-unavailable")
    else
      self.setup_output = output
      self:set_state("setup-failed")
    end
  end)
end


function InstallPanel:skip_setup()
  access.record_setup(self.setup.id, self.setup.version, "skipped")
  core.add_thread(access.check_setups)
  self.view:finish_install(self.platform.id, "Installed " .. self.platform.name
    .. ". USB setup was skipped; you can run it later from the welcome screen. Now choose your board.")
end


function InstallPanel:toggle_script()
  if self.script_lines then
    self.script_lines = nil
  else
    self.script_lines = {}
    local fp = io.open(self.setup.script)
    if fp then
      for line in fp:lines() do table.insert(self.script_lines, (line:gsub("\t", "    "))) end
      fp:close()
    end
  end
  core.redraw = true
end


function InstallPanel:copy_setup_command()
  local text = access.terminal_command({ "/bin/bash", self.setup.script })
  system.set_clipboard(text)
  core.log("Copied: %s", text)
end


-------------------------------------------------------------------------------
-- Panel interface used by the New Project page
-------------------------------------------------------------------------------

---Buttons for the current state: { back?, extra?, next?, hint }.
function InstallPanel:buttons()
  local s = self.state
  local close = function() self.view:close_panel() end
  if s == "confirm" then
    return { back = { text = "Not Now", run = close },
      next = { text = "Download and Install", run = function() self:start() end },
      hint = "Enter: install    Esc: not now" }
  elseif s == "running" then
    return { next = { text = "Cancel", run = function() self:cancel() end, enabled = not self.handle.cancelled,
      primary = false }, hint = "" }
  elseif s == "confirm-cancel" then
    return { back = { text = "Stop Anyway", run = function() self:stop() end },
      next = { text = "Keep Installing", run = function() self:set_state("running") end },
      hint = "Enter or Esc: keep installing" }
  elseif s == "failed" then
    return { back = { text = "←  Back", run = close }, next = { text = "Try Again", run = function() self:start() end },
      hint = "Enter: try again    Esc: go back" }
  elseif s == "incomplete" then
    return { back = { text = "Repair Later", run = function()
        self.view:close_panel(self.platform.name .. " is still half installed. Repair it from the welcome screen "
          .. "or by choosing it again.", true)
      end },
      next = { text = "Repair Now", run = function() self:start() end },
      hint = "Enter: repair now    Esc: later" }
  elseif s == "setup" then
    return { back = { text = "Skip", run = function() self:skip_setup() end },
      extra = { text = self.script_lines and "Hide Script" or "Show Script", run = function() self:toggle_script() end },
      next = { text = "Set Up Now", run = function() self:start_setup() end } }
  elseif s == "setup-running" then
    return { next = { text = "Waiting...", enabled = false }, hint = "" }
  elseif s == "setup-failed" then
    return { back = { text = "Skip", run = function() self:skip_setup() end },
      next = { text = "Try Again", run = function() self:start_setup() end },
      hint = "Enter: try again    Esc: skip" }
  elseif s == "setup-unavailable" then
    return { extra = { text = "Copy Command", run = function() self:copy_setup_command() end },
      next = { text = "Continue", run = function() self:skip_setup() end } }
  end
  return {}
end


-- Enter runs the primary button, except while running (Cancel must be clicked).
function InstallPanel:enter()
  if self.state == "running" then return end
  local next = self:buttons().next
  if next and next.run and next.enabled ~= false then next.run() end
end


-- Esc: the safe choice. It never stops a running install.
function InstallPanel:escape()
  local s = self.state
  if s == "running" or s == "setup-running" then return end
  if s == "confirm-cancel" then
    self:set_state("running")
    return
  end
  local back = self:buttons().back
  if back and back.run then back.run() end
end
-- the install panel has no text to delete
function InstallPanel:backspace() end


function InstallPanel:on_close()
  if self.state == "running" or self.state == "confirm-cancel" then
    self.handle.cancelled = true
    core.log("Cancelled installing %s", self.platform.name)
  end
end


function InstallPanel:draw(rect)
  local pad_x, pad_y = style.padding.x, style.padding.y
  local platform = self.platform
  renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, style.background2)
  core.push_clip_rect(rect.x, rect.y, rect.w, rect.h)
  local W = ui.writer(rect.x + pad_x, rect.y + pad_y, rect.w - pad_x * 2)
  local s = self.state

  local function explained_error()
    local explanation = cli.explain_error((self.error or "") .. "\n" .. (self.details or ""))
    if explanation then W.paragraph(explanation, style.text) end
    W.paragraph("Details: " .. (self.details and self.details ~= "" and self.details or self.error or "unknown error"),
      style.dim)
  end

  local version = platform.platform and platform.platform.latest_version or ""
  if s == "confirm" then
    W.paragraph(platform.name .. " is not installed yet", style.accent)
    W.paragraph("Superduino can download and install it for you. Then you can choose your board.", style.text)
    local boards = examples(platform.board_names)
    if boards then W.paragraph("Boards in this family: " .. boards .. ".", style.dim) end
    W.paragraph("Package: " .. platform.id .. (version ~= "" and ("  version " .. version) or "")
      .. "  from " .. (platform.vendor_name or "?"), style.dim)
    W.paragraph("Downloading needs an internet connection and can take a few minutes for large families.", style.dim)
  elseif s == "running" or s == "confirm-cancel" then
    W.paragraph((self.mode == "repair" and "Repairing " or "Installing ") .. platform.name, style.accent)
    if s == "confirm-cancel" then
      W.paragraph("Stop now? Files are being unpacked. Stopping now leaves " .. platform.name
        .. " half installed: its boards will not work until it is repaired.", style.error)
    end
    W.paragraph(self.current or "", style.text)
    local bar_h = math.floor(8 * SCALE)
    local percent = self.progress and self.progress.percent or 0
    renderer.draw_rect(W.x, W.y, W.w, bar_h, style.line_highlight)
    renderer.draw_rect(W.x, W.y, math.floor(W.w * common.clamp(percent, 0, 100) / 100), bar_h, style.caret)
    W.gap(bar_h + pad_y)
    local p = self.progress
    if p then
      local parts = { string.format("%s of %s", p.done, p.total), string.format("%.0f%%", p.percent) }
      if p.eta then table.insert(parts, (p.eta:gsub("^00m", "")) .. " left") end
      W.paragraph(table.concat(parts, "   ·   "), style.dim)
    else
      W.gap(style.font:get_height() + pad_y)
    end
    if #self.done > 0 then
      W.paragraph("Done so far:", style.dim)
      local line_h = style.font:get_height() + pad_y / 2
      local fits = math.max(1, math.floor((rect.y + rect.h - W.y) / line_h) - 1)
      for i = math.max(1, #self.done - fits + 1), #self.done do
        common.draw_text(style.font, style.dim, "  " .. self.done[i], "left", W.x, W.y, 0, line_h)
        W.y = W.y + line_h
      end
    end
  elseif s == "failed" then
    W.paragraph("Could not install " .. platform.name, style.error)
    explained_error()
    W.paragraph("Nothing was changed; you can try again.", style.dim)
  elseif s == "incomplete" then
    W.paragraph("Warning: " .. platform.name .. " is only half installed", style.error)
    if self.note then W.paragraph(self.note, style.text) end
    W.paragraph("Boards of this family will not compile or upload correctly until it is repaired. Repairing "
      .. "removes what was installed and installs it again.", style.text)
    if self.error then explained_error() end
    W.paragraph("You can repair it now or later: the welcome screen keeps reminding you until it is fixed.", style.dim)
  else
    local setup = self.setup
    W.paragraph(platform.name .. " is installed. One more step: USB access", style.accent)
    if s == "setup-running" then
      W.paragraph("Waiting for your password in the system dialog...", style.text)
    elseif s == "setup-failed" then
      W.paragraph("The setup script failed:", style.error)
      W.paragraph(self.setup_output ~= "" and self.setup_output or "no output", style.text)
    elseif s == "setup-unavailable" then
      W.paragraph("Superduino could not show a password dialog because pkexec is not installed. "
        .. "You can run this command in a terminal instead:", style.text)
      W.paragraph(access.terminal_command({ "/bin/bash", setup.script }), style.accent)
    else
      W.paragraph("Some boards in this family use a special USB mode for uploading. Linux needs a permission rule "
        .. "(a udev rule) for it, which this family provides as a setup script.", style.text)
      W.paragraph("It runs once as administrator; your computer will ask for your password. You can also skip it "
        .. "and run it later from the welcome screen.", style.dim)
      if self.setup_note then W.paragraph(self.setup_note, style.warn) end
    end
    local line_h = style.font:get_height() + pad_y / 2
    local label_end = common.draw_text(style.font, style.dim, "Script:", "left", W.x, W.y, 0, line_h)
    local path_x = label_end + pad_x / 2
    common.draw_text(style.font, style.dim,
      EmptyView.shorten_path(style.font, common.home_encode(setup.script), W.x + W.w - path_x), "left", path_x, W.y, 0, line_h)
    W.gap(line_h + pad_y / 2)
    if self.script_lines then
      renderer.draw_rect(W.x, W.y, W.w, math.max(0, rect.y + rect.h - W.y - pad_y), style.background)
      local code_h = style.code_font:get_height() + math.floor(2 * SCALE)
      local cy = W.y + pad_y / 2
      for _, line in ipairs(self.script_lines) do
        if cy > rect.y + rect.h then break end
        common.draw_text(style.code_font, style.text, line, "left", W.x + pad_x / 2, cy, 0, code_h)
        cy = cy + code_h
      end
    end
  end
  core.pop_clip_rect()
end


return InstallPanel
