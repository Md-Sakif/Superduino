-- The Build section in the left side pane, between the file tree and the Board
-- panel: Build and Upload buttons, the port to upload to, and the result of the
-- last build or upload of the open sketch.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local cli = require "plugins.arduino.cli"
local build = require "plugins.arduino.build"
local ports = require "plugins.arduino.ports"
local monitor = require "plugins.arduino.serial_monitor"
local ui = require "plugins.arduino.ui"
local BoardPanel = require "plugins.arduino.board_panel"
local OutputView = require "plugins.arduino.output_view"

---@class arduino.buildpanel : core.view
local BuildPanel = View:extend()

function BuildPanel:__tostring() return "BuildPanel" end

BuildPanel.save_in_workspace = false


---The open sketch with its port: { dir, fqbn?, port?: arduino.port }, or nil.
function BuildPanel.sketch()
  local info = BoardPanel.current()
  if not info then return nil end
  local port = ports.for_sketch(info.dir, info.fqbn)
  return { dir = info.dir, fqbn = info.fqbn, port = port }
end


local function ready()
  if cli.status == "ok" then return true end
  core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
  return false
end


---Builds the open sketch.
function BuildPanel.build()
  local sketch = BuildPanel.sketch()
  if not sketch or build.running() or not ready() then return end
  build.start("build", sketch.dir, nil, sketch.fqbn)
end


---Builds and uploads the open sketch; asks for a port first when there is none.
function BuildPanel.upload()
  local sketch = BuildPanel.sketch()
  if not sketch or build.running() or not ready() then return end
  local locked = monitor.locked()
  if locked then
    core.warn("%s", locked)
    return
  end
  if sketch.port then
    build.start("upload", sketch.dir, sketch.port.address, sketch.fqbn)
  else
    BuildPanel.choose_port(function(address) build.start("upload", sketch.dir, address, sketch.fqbn) end)
  end
end


---Lets the user choose the port of the open sketch, then calls `on_chosen`.
---@param on_chosen? fun(address: string)
function BuildPanel.choose_port(on_chosen)
  local sketch = BuildPanel.sketch()
  if not sketch then return end
  if ports.state ~= "watching" then core.add_thread(ports.refresh) end
  local function items(text)
    local list = {}
    local needle = text:lower()
    for _, port in ipairs(ports.list) do
      local info = ports.describe(port)
      if (port.address .. " " .. info):lower():find(needle, 1, true) then
        table.insert(list, { text = port.address, info = info })
      end
    end
    return list
  end
  core.command_view:enter("Board Port", {
    submit = function(text, item)
      local address = item and item.text or text:gsub("^%s+", ""):gsub("%s+$", "")
      if address == "" then return end
      ports.save(sketch.dir, address)
      if on_chosen then on_chosen(address) end
    end,
    suggest = items,
    validate = function(text, item) return item ~= nil or text:match("%S") ~= nil end,
  })
end


-------------------------------------------------------------------------------
-- The view
-------------------------------------------------------------------------------

function BuildPanel:new()
  BuildPanel.super.new(self)
  self.hovered_id = nil
  self.init_size = true
end


function BuildPanel:line_height()
  return style.font:get_height() + style.padding.y
end


---Text of the status line, its color, and a detail line (memory use), for the open sketch.
function BuildPanel:status(sketch)
  if not sketch.fqbn then return "Choose a board first (see Board below).", style.warn end
  local run = build.last
  if not run or run.dir ~= sketch.dir then return nil end
  if run.state == "running" then
    return run.kind == "upload" and "Uploading..." or "Building...", style.accent
  elseif run.state == "done" then
    local parts = {}
    if run.flash then table.insert(parts, "Flash " .. run.flash .. "%") end
    if run.ram then table.insert(parts, "RAM " .. run.ram .. "%") end
    return run.kind == "upload" and ("Uploaded to " .. tostring(run.port)) or "Build done", style.good,
      #parts > 0 and table.concat(parts, "  ·  ") or nil
  elseif run.state == "cancelled" then
    return (run.kind == "upload" and "Upload" or "Build") .. " cancelled", style.warn
  end
  local what = run.kind == "upload" and "Upload failed" or "Build failed"
  if run.errors > 0 then
    what = what .. string.format(": %d error%s", run.errors, run.errors == 1 and "" or "s")
  end
  return what, style.error
end


function BuildPanel:layout(sketch)
  local font, pad_x, pad_y = style.font, style.padding.x, style.padding.y
  local line_h = self:line_height()
  local x, w = self.position.x, self.size.x
  local L = { header_y = pad_y, targets = {}, buttons = {} }
  local y = pad_y + line_h
  -- borderless buttons with the Arduino IDE's icons: a check mark to build (verify),
  -- an arrow to upload; Cancel while running
  local specs
  if build.running() then
    specs = { { id = "build:cancel", text = build.last.kind == "upload" and "Cancel Upload" or "Cancel Build",
      icon = "C", icon_font = style.icon_font, run = build.cancel } }
  else
    specs = {
      { id = "build:build", text = "Build", icon = "V", run = BuildPanel.build, enabled = sketch.fqbn ~= nil },
      -- (not while the Serial Monitor holds the port)
      { id = "build:upload", text = "Upload", icon = "U", run = BuildPanel.upload,
        enabled = sketch.fqbn ~= nil and not monitor.locked() },
    }
  end
  -- one row each, clickable across the pane like the Port row
  for _, spec in ipairs(specs) do
    local b = { id = spec.id, text = spec.text, icon = spec.icon, icon_font = spec.icon_font, x = x, y = y,
      w = w, h = line_h, enabled = spec.enabled ~= false }
    table.insert(L.buttons, b)
    if b.enabled then table.insert(L.targets, { id = b.id, x = b.x, y = b.y, w = b.w, h = b.h, run = spec.run }) end
    y = y + line_h
  end
  -- the port row is clickable as a whole (not while the Serial Monitor uses the port)
  L.port_y = y
  if not monitor.locked() then
    table.insert(L.targets, { id = "build:port", x = x, y = y, w = w, h = line_h,
      run = function() BuildPanel.choose_port() end })
  end
  y = y + line_h
  -- while the Serial Monitor holds the port: why Upload and the board are
  -- locked, and a way to free it
  if monitor.locked() then
    L.serial_y = y
    table.insert(L.targets, { id = "build:disconnect", x = x, y = y, w = w, h = line_h,
      run = function() monitor.disconnect() end })
    y = y + line_h
  end
  local status, color, detail = self:status(sketch)
  if status then
    L.status = { text = status, color = color, detail = detail, y = y }
    local status_h = line_h * (detail and 2 or 1)
    table.insert(L.targets, { id = "build:status", x = x, y = y, w = w, h = status_h,
      run = function() OutputView.get():show() end })
    y = y + status_h
  end
  L.height = y + pad_y
  return L
end


function BuildPanel:update()
  local sketch = BuildPanel.sketch()
  self.sketch_info = sketch
  if sketch and ports.state == "idle" then ports.start() end
  self.current_layout = sketch and self:layout(sketch)
  local dest = self.current_layout and self.current_layout.height or 0
  if self.init_size then
    self.size.y, self.init_size = dest, nil
  else
    self:move_towards(self.size, "y", dest)
  end
  BuildPanel.super.update(self)
end


function BuildPanel:target_at(x, y)
  local L = self.current_layout
  if not L then return nil end
  local ry = y - self.position.y
  for _, target in ipairs(L.targets) do
    if x >= target.x and x < target.x + target.w and ry >= target.y and ry < target.y + target.h then return target end
  end
end


function BuildPanel:on_mouse_moved(x, y, ...)
  BuildPanel.super.on_mouse_moved(self, x, y, ...)
  local target = self:target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = target and "hand" or "arrow"
end


function BuildPanel:on_mouse_left()
  BuildPanel.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function BuildPanel:on_mouse_pressed(button, x, y)
  local target = button == "left" and self:target_at(x, y)
  if target then target.run() end
  return true
end


function BuildPanel:draw()
  local L, sketch = self.current_layout, self.sketch_info
  if self.size.y < 1 or not L then return end
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  core.push_clip_rect(x, y, w, h)
  local font, pad_x = style.font, style.padding.x
  local line_h = self:line_height()
  local function text_at(color, text, tx, ty, max_w)
    return common.draw_text(font, color, ui.truncate(font, text, max_w), "left", tx, y + ty, 0, line_h)
  end
  local function hover_row(id, ry)
    local hovered = self.hovered_id == id
    if hovered then renderer.draw_rect(x, y + ry, w, line_h, style.line_highlight) end
    return hovered
  end

  text_at(style.dim, "BUILD", x + pad_x, L.header_y, w)
  for _, b in ipairs(L.buttons) do
    ui.draw_flat_button({ x = b.x, y = y + b.y, w = b.w, h = b.h, text = b.text, icon = b.icon,
      icon_font = b.icon_font, enabled = b.enabled }, self.hovered_id == b.id)
  end

  local hovered = hover_row("build:port", L.port_y)
  local label_end = text_at(style.dim, "Port", x + pad_x, L.port_y, w)
  local value_x = label_end + pad_x / 2
  local value_w = x + w - pad_x - value_x
  if sketch.port then
    local end_x = text_at(hovered and style.accent or style.text, sketch.port.address, value_x, L.port_y, value_w)
    text_at(style.dim, ports.describe(sketch.port), end_x + pad_x / 2, L.port_y, x + w - pad_x - end_x - pad_x / 2)
  elseif #ports.list > 0 then
    text_at(hovered and style.accent or style.warn, "Choose...", value_x, L.port_y, value_w)
  else
    text_at(hovered and style.accent or style.dim, "No board connected", value_x, L.port_y, value_w)
  end

  if L.serial_y then
    local disconnect_hovered = hover_row("build:disconnect", L.serial_y)
    local label_end2 = text_at(style.dim, "Serial", x + pad_x, L.serial_y, w)
    local state_x = label_end2 + pad_x / 2
    local state_end = text_at(style.good, monitor.state() == "waiting" and "waiting" or "connected", state_x,
      L.serial_y, x + w - pad_x - state_x)
    text_at(disconnect_hovered and style.accent or style.dim, "Disconnect", state_end + pad_x / 2, L.serial_y,
      x + w - pad_x - state_end - pad_x / 2)
  end

  if L.status then
    local status_hovered = self.hovered_id == "build:status"
    if status_hovered then
      renderer.draw_rect(x, y + L.status.y, w, line_h * (L.status.detail and 2 or 1), style.line_highlight)
    end
    text_at(status_hovered and style.accent or L.status.color, L.status.text, x + pad_x, L.status.y, w - pad_x * 2)
    if L.status.detail then
      text_at(style.dim, L.status.detail, x + pad_x, L.status.y + line_h, w - pad_x * 2)
    end
  end
  core.pop_clip_rect()
end


---Adds the section between the file tree and the Board panel (once both exist).
function BuildPanel.dock()
  core.add_thread(function()
    local ok, treeview = pcall(require, "plugins.treeview")
    if not ok or type(treeview) ~= "table" or not treeview.node then return end
    local node = core.root_view.root_node:get_node_for_view(treeview)
    if not node then return end
    BuildPanel.view = BuildPanel()
    node:split("down", BuildPanel.view, { y = true })
  end)
end


-- a changed arduino-cli is followed from the start
table.insert(cli.on_checked, function() ports.stop() end)


command.add(function() return BuildPanel.sketch() ~= nil end, {
  ["arduino:build"] = BuildPanel.build,
  -- (says why when the Serial Monitor holds the port)
  ["arduino:upload"] = BuildPanel.upload,
})

command.add(function() return BuildPanel.sketch() ~= nil and not monitor.locked() end, {
  ["arduino:select-port"] = function() BuildPanel.choose_port() end,
})

command.add(function() return build.running() end, {
  ["arduino:cancel-build"] = build.cancel,
})

command.add(nil, {
  ["arduino:show-output"] = function() OutputView.get():show() end,
  ["arduino:hide-output"] = function() if OutputView.view then OutputView.view:hide() end end,
})


return BuildPanel
