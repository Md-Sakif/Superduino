-- The Serial Monitor panel under the editor: what the board prints, and a box
-- to send text to it. It uses the Build section's port and connects when shown.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local monitor = require "plugins.arduino.serial_monitor"
local bottom_panels = require "plugins.arduino.bottom_panels"
local BuildPanel = require "plugins.arduino.build_panel"
local ui = require "plugins.arduino.ui"

---@class arduino.serialview : core.view
local SerialView = View:extend()

function SerialView:__tostring() return "SerialView" end

SerialView.save_in_workspace = false

SerialView.DEFAULT_HEIGHT = 220
-- sent texts kept for Up/Down
local HISTORY_SIZE = 50


function SerialView:new()
  SerialView.super.new(self)
  self.scrollable = true
  self.visible = false
  self.target_height = SerialView.DEFAULT_HEIGHT * SCALE
  self.hovered_id = nil
  self.targets = {}
  self.shown_count = 0
  self.input = ""
  self.history, self.history_pos = {}, nil
end


function SerialView:get_name() return "Serial Monitor" end


function SerialView:set_target_size(axis, value)
  if axis ~= "y" then return false end
  self.target_height = math.max(value, self:header_height() * 3)
  return true
end


function SerialView:header_height()
  return style.font:get_height() + style.padding.y * 2
end


function SerialView:input_height()
  return style.font:get_height() + style.padding.y * 2
end


function SerialView:line_height()
  return style.code_font:get_height() + math.floor(style.padding.y / 3)
end


local function line_count()
  return #monitor.lines + (monitor.partial and 1 or 0)
end


local function line_at(i)
  return monitor.lines[i] or (i == #monitor.lines + 1 and monitor.partial) or nil
end


function SerialView:get_scrollable_size()
  return self:header_height() + line_count() * self:line_height() + style.padding.y * 2 + self:input_height()
end


---The open sketch's connection target: { port, baud, fqbn, protocol, dir }, or nil
---(and why) when there is no sketch or port.
function SerialView.target()
  local sketch = BuildPanel.sketch()
  if not sketch then return nil, "no-sketch" end
  if not sketch.port then return nil, "no-port" end
  return { port = sketch.port.address, protocol = sketch.port.protocol, fqbn = sketch.fqbn,
    baud = monitor.baud_for(sketch.dir), dir = sketch.dir }
end


---Connects to the open sketch's port; asks for a port first when there is none.
function SerialView.connect()
  local target, why = SerialView.target()
  if target then
    monitor.connect(target)
  elseif why == "no-port" then
    BuildPanel.choose_port(function() SerialView.connect() end)
  else
    core.warn("Open a sketch to use the serial monitor")
  end
end


function SerialView:show(focus)
  bottom_panels.showing("serial")
  if not self.visible then
    self.visible = true
    self.scroll.to.y = math.huge
    core.redraw = true
    -- like the Arduino IDE: opening the monitor connects
    if monitor.state() == "disconnected" and SerialView.target() then SerialView.connect() end
  end
  if focus and core.active_view ~= self then
    self.previous_view = core.active_view
    core.set_active_view(self)
  end
end


---Gives the keyboard back to the view that had it before the box.
function SerialView:leave()
  if core.active_view ~= self then return end
  local previous = self.previous_view
  if previous and previous ~= self and core.root_view.root_node:get_node_for_view(previous) then
    core.set_active_view(previous)
  else
    core.set_active_view(core.root_view:get_primary_node().active_view)
  end
end


function SerialView:hide()
  self.visible = false
  self:leave()
  core.redraw = true
end


function SerialView:supports_text_input()
  return self.visible
end


function SerialView:on_text_input(text)
  self.input = self.input .. text:gsub("[\r\n]", "")
  self.history_pos = nil
  core.redraw = true
end


function SerialView:send()
  local text = self.input
  if monitor.state() ~= "connected" and monitor.state() ~= "connecting" then
    core.warn("The serial monitor is not connected")
    return
  end
  monitor.send(text)
  if text ~= "" and self.history[#self.history] ~= text then
    table.insert(self.history, text)
    if #self.history > HISTORY_SIZE then table.remove(self.history, 1) end
  end
  self.input, self.history_pos = "", nil
  core.redraw = true
end


---Moves through the sent texts (-1 older, 1 newer).
function SerialView:browse_history(dir)
  if #self.history == 0 then return end
  local pos = (self.history_pos or (#self.history + 1)) + dir
  if pos > #self.history then
    self.input, self.history_pos = "", nil
  else
    self.history_pos = common.clamp(pos, 1, #self.history)
    self.input = self.history[self.history_pos]
  end
  core.redraw = true
end


function SerialView:copy()
  local text = monitor.text(monitor.timestamps())
  if text == "" then return end
  system.set_clipboard(text .. "\n")
  core.log("Copied the serial monitor (%d lines)", line_count())
end


---Lets the user choose the baud rate of the open sketch, then connects at it.
function SerialView.choose_baud()
  local sketch = BuildPanel.sketch()
  if not sketch then return end
  local current, _, file = monitor.baud_for(sketch.dir)
  if monitor.session then current = monitor.session.baud end
  local detected = monitor.detect_baud(sketch.dir)
  -- the current rate first, so Enter keeps it
  local items = {}
  for _, baud in ipairs(monitor.BAUD_RATES) do
    local info = baud == detected and ("Serial.begin in " .. tostring(file)) or nil
    if baud == current then info = info and (info .. ", current") or "current" end
    table.insert(items, baud == current and 1 or #items + 1, { text = tostring(baud), info = info })
  end
  core.command_view:enter("Baud Rate", {
    text = "",
    submit = function(text, item)
      local baud = tonumber(item and item.text or text)
      if not baud then return end
      monitor.choose_baud(sketch.dir, baud)
      -- connecting again restarts many boards (e.g. Uno, Nano): only for another rate
      local state = monitor.state()
      if baud ~= current and (state == "connected" or state == "connecting" or state == "waiting") then
        SerialView.connect()
      end
    end,
    suggest = function(text)
      local list = {}
      for _, item in ipairs(items) do
        if item.text:find(text, 1, true) then table.insert(list, item) end
      end
      return list
    end,
    validate = function(text, item) return item ~= nil or tonumber(text) ~= nil end,
  })
end


---Lets the user choose what is added after sent text.
function SerialView.choose_line_ending()
  local current = monitor.line_ending()
  -- the current one first, so Enter keeps it
  local items = {}
  for _, ending in ipairs(monitor.LINE_ENDINGS) do
    local is_current = ending.id == current.id
    table.insert(items, is_current and 1 or #items + 1,
      { text = ending.label, info = is_current and "current" or nil, id = ending.id })
  end
  core.command_view:enter("Line Ending", {
    submit = function(_, item) if item then monitor.set_line_ending(item.id) end end,
    suggest = function(text)
      local list = {}
      for _, item in ipairs(items) do
        if item.text:lower():find(text:lower(), 1, true) then table.insert(list, item) end
      end
      return list
    end,
    validate = function(_, item) return item ~= nil end,
  })
end


function SerialView:update()
  local dest = self.visible and self.target_height or 0
  self:move_towards(self.size, "y", dest, nil, "serial")
  local count = monitor.dropped + line_count()
  if count ~= self.shown_count then
    -- keep the end in view while text arrives, unless scrolled up to read
    local line_h = self:line_height()
    local shown = self.shown_count - monitor.dropped
    local old_end = self:header_height() + shown * line_h + style.padding.y * 2 + self:input_height() - self.size.y
    if count < self.shown_count or self.scroll.to.y >= old_end - line_h then self.scroll.to.y = math.huge end
    self.shown_count = count
  end
  SerialView.super.update(self)
  self:layout()
end


---The connection's state for a header, e.g. "/dev/ttyUSB0 at 115200 baud", and its color.
function SerialView.state_text()
  local state = monitor.state()
  local session = monitor.session
  if state == "connected" then
    return string.format("%s at %d baud", session.port, session.baud), style.good
  elseif state == "connecting" then
    return "connecting to " .. session.port .. "...", style.accent
  elseif state == "paused" then
    return "paused while uploading", style.warn
  elseif state == "waiting" then
    return "waiting for " .. monitor.waiting.port .. " to come back", style.warn
  end
  return "not connected", style.dim
end


---Title of the header and its color.
function SerialView:title()
  local text, color = SerialView.state_text()
  return "Serial Monitor: " .. text, color
end


-- Clickable areas (in screen coordinates).
function SerialView:layout()
  self.targets = {}
  local font, pad_x, pad_y = style.font, style.padding.x, style.padding.y
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local header_h = self:header_height()
  local state = monitor.state()
  local sketch = BuildPanel.sketch()
  local baud = sketch and monitor.baud_for(sketch.dir)
  if monitor.session then baud = monitor.session.baud end
  local connected = state ~= "disconnected"

  -- header links, right to left
  local right = x + w - pad_x
  self.links = {}
  for _, link in ipairs({
    { id = "serial:hide", text = "Hide", run = function() self:hide() end },
    { id = "serial:copy", text = "Copy", run = function() self:copy() end, enabled = line_count() > 0 },
    { id = "serial:clear", text = "Clear", run = monitor.clear, enabled = line_count() > 0 },
    { id = "serial:timestamps", text = "Timestamps", on = monitor.timestamps(),
      run = function() monitor.set_timestamps(not monitor.timestamps()) end },
    connected and { id = "serial:disconnect", text = "Disconnect", run = function() monitor.disconnect() end }
      or { id = "serial:connect", text = "Connect", run = SerialView.connect, enabled = sketch ~= nil },
    { id = "serial:baud", text = (baud or monitor.DEFAULT_BAUD) .. " baud", run = SerialView.choose_baud,
      enabled = sketch ~= nil },
  }) do
    local lw = font:get_width(link.text) + pad_x
    link.x, link.y, link.w, link.h = right - lw, y, lw, header_h
    right = right - lw
    if link.enabled ~= false then table.insert(self.targets, link) end
    table.insert(self.links, link)
  end
  self.title_w = right - x - pad_x * 2

  -- the input row: the box, the line ending, Send
  local row_h = self:input_height()
  local row_y = y + h - row_h
  local ending = monitor.line_ending()
  local send_w = font:get_width("Send") + pad_x * 2
  local ending_w = font:get_width(ending.label) + pad_x * 2
  self.send_button = { id = "serial:send", text = "Send", x = x + w - pad_x / 2 - send_w, y = row_y, w = send_w, h = row_h,
    enabled = state == "connected" or state == "connecting", run = function() self:send() end }
  self.ending_button = { id = "serial:line-ending", text = ending.label, x = self.send_button.x - ending_w, y = row_y,
    w = ending_w, h = row_h, enabled = true, run = SerialView.choose_line_ending }
  local box_h = font:get_height() + pad_y
  self.input_box = { id = "serial:input", x = x + pad_x, y = row_y + (row_h - box_h) / 2,
    w = math.max(0, self.ending_button.x - pad_x / 2 - x - pad_x), h = box_h,
    run = function() self:show(true) end }
  self.input_row = { x = x, y = row_y, w = w, h = row_h }
  for _, target in ipairs({ self.input_box, self.ending_button, self.send_button }) do
    if target.enabled ~= false then table.insert(self.targets, target) end
  end

  -- clickable hints
  local ox, oy = self:get_content_offset()
  local line_h = self:line_height()
  local first = math.max(1, math.floor((self.scroll.y - header_h) / line_h))
  for i = first, math.min(line_count(), first + math.ceil(h / line_h) + 1) do
    local line = line_at(i)
    if line and line.command then
      local ly = oy + header_h + (i - 1) * line_h
      table.insert(self.targets, { id = "line:" .. i, x = x, y = ly, w = w, h = line_h,
        run = function() command.perform(line.command) end })
    end
  end
end


function SerialView:target_at(x, y)
  -- the header and the input row are on top of the lines
  local in_header = y < self.position.y + self:header_height()
  local in_row = self.input_row and y >= self.input_row.y
  for _, target in ipairs(self.targets) do
    local is_line = target.id:find("^line:") ~= nil
    if (not is_line or not (in_header or in_row))
      and x >= target.x and x < target.x + target.w and y >= target.y and y < target.y + target.h then
      return target
    end
  end
end


function SerialView:on_mouse_moved(x, y, ...)
  SerialView.super.on_mouse_moved(self, x, y, ...)
  local target = self:target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = target and (id == "serial:input" and "ibeam" or "hand") or "arrow"
end


function SerialView:on_mouse_left()
  SerialView.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function SerialView:on_mouse_pressed(button, x, y, clicks)
  if SerialView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local target = button == "left" and self:target_at(x, y)
  if target then target.run() end
  return true
end


local LINE_COLORS = { rx = "text", info = "dim", error = "error", hint = "accent" }


---What the empty panel says.
local function empty_message()
  local state = monitor.state()
  if state ~= "disconnected" then return "Nothing received yet. Text the board prints with Serial.print() shows here." end
  local _, why = SerialView.target()
  if why == "no-sketch" then return "Open a sketch to use the serial monitor." end
  if why == "no-port" then return "No board connected. Plug one in, then click Connect." end
  return "Not connected. Click Connect to see what the board prints."
end


function SerialView:draw()
  if self.size.y < 1 then return end
  self:layout()
  self:draw_background(style.background)
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local pad_x = style.padding.x
  local header_h = self:header_height()
  local row = self.input_row

  core.push_clip_rect(x, y + header_h, w, math.max(0, row.y - y - header_h))
  if line_count() == 0 then
    common.draw_text(style.font, style.dim, empty_message(), "left", x + pad_x, y + header_h + style.padding.y, 0,
      style.font:get_height())
  else
    local ox, oy = self:get_content_offset()
    local line_h = self:line_height()
    local stamps = monitor.timestamps()
    local stamp_w = stamps and style.code_font:get_width("00:00:00.000  ") or 0
    local first = math.max(1, math.floor((self.scroll.y - header_h) / line_h))
    for i = first, math.min(line_count(), first + math.ceil(h / line_h) + 1) do
      local line = line_at(i)
      local ly = oy + header_h + (i - 1) * line_h
      if line.command and self.hovered_id == "line:" .. i then
        renderer.draw_rect(x, ly, w, line_h, style.line_highlight)
      end
      if stamps then
        common.draw_text(style.code_font, style.dim, monitor.format_time(line.time), "left", x + pad_x, ly, 0, line_h)
      end
      local color = style[LINE_COLORS[line.kind] or "text"] or style.text
      common.draw_text(style.code_font, color, line.text, "left", x + pad_x + stamp_w, ly, 0, line_h)
    end
  end
  core.pop_clip_rect()

  -- the input row under the lines
  renderer.draw_rect(row.x, row.y, row.w, row.h, style.background2)
  renderer.draw_rect(row.x, row.y, row.w, math.max(1, SCALE), style.divider)
  local connected = monitor.state() == "connected" or monitor.state() == "connecting"
  ui.draw_text_box(self.input_box, self.input,
    connected and "Text to send to the board (Enter)" or "Connect to send text to the board",
    core.active_view == self)
  for _, button in ipairs({ self.ending_button, self.send_button }) do
    ui.draw_flat_button(button, self.hovered_id == button.id)
  end

  -- the header over the lines
  renderer.draw_rect(x, y, w, header_h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  local title, color = self:title()
  common.draw_text(style.font, color, ui.truncate(style.font, title, self.title_w or w), "left", x + pad_x, y, 0, header_h)
  for _, link in ipairs(self.links or {}) do
    local hovered = self.hovered_id == link.id
    local link_color = link.enabled == false and style.dim
      or (hovered and style.accent or (link.on and style.accent or style.text))
    common.draw_text(style.font, link_color, link.text, "center", link.x, link.y, link.w, link.h)
  end
  self:draw_scrollbar()
end


---The panel, added under the editor the first time it is needed.
---@return arduino.serialview
function SerialView.get()
  if not SerialView.view then
    SerialView.view = SerialView()
    local node = core.root_view:get_primary_node()
    node:split("down", SerialView.view, { y = true }, true)
  end
  return SerialView.view
end


function SerialView.is_open()
  return SerialView.view ~= nil and SerialView.view.visible
end


bottom_panels.add({ id = "serial", is_open = SerialView.is_open, close = function() SerialView.view:hide() end,
  show = function() SerialView.get():show() end })


-- an upload hides the Serial Monitor or Plotter behind the Output panel; bring
-- it back when the upload worked
local shown_before_upload = nil
table.insert(monitor.on_pause, function() shown_before_upload = bottom_panels.shown() end)
table.insert(monitor.on_resume, function(run)
  local id = shown_before_upload
  shown_before_upload = nil
  if (id == "serial" or id == "plotter") and run.state == "done" then bottom_panels.show(id) end
end)


command.add(nil, {
  ["arduino:toggle-serial-monitor"] = function()
    if SerialView.is_open() then SerialView.view:hide() else SerialView.get():show(true) end
  end,
  ["arduino:show-serial-monitor"] = function() SerialView.get():show(true) end,
})

command.add(function() return BuildPanel.sketch() ~= nil and not monitor.active() end, {
  ["arduino:serial-connect"] = function()
    SerialView.get():show()
    SerialView.connect()
  end,
})

command.add(function() return monitor.active() end, {
  ["arduino:serial-disconnect"] = function() monitor.disconnect() end,
})

command.add(function() return BuildPanel.sketch() ~= nil end, {
  ["arduino:serial-baud-rate"] = SerialView.choose_baud,
})

command.add(nil, {
  ["arduino:serial-line-ending"] = SerialView.choose_line_ending,
  ["arduino:serial-clear"] = monitor.clear,
  ["arduino:serial-toggle-timestamps"] = function() monitor.set_timestamps(not monitor.timestamps()) end,
})

-- typing in the panel's box
command.add(SerialView, {
  ["serial-monitor:send"] = function(view) view:send() end,
  ["serial-monitor:backspace"] = function(view)
    view.input = ui.remove_last_char(view.input)
    core.redraw = true
  end,
  ["serial-monitor:clear-input"] = function(view)
    view.input = ""
    core.redraw = true
  end,
  ["serial-monitor:paste"] = function(view) view:on_text_input((system.get_clipboard() or ""):gsub("\n.*", "")) end,
  ["serial-monitor:previous-sent"] = function(view) view:browse_history(-1) end,
  ["serial-monitor:next-sent"] = function(view) view:browse_history(1) end,
  ["serial-monitor:leave"] = function(view) view:leave() end,
})

keymap.add({
  ["ctrl+shift+m"] = "arduino:toggle-serial-monitor",
  ["return"] = "serial-monitor:send",
  ["keypad enter"] = "serial-monitor:send",
  ["backspace"] = "serial-monitor:backspace",
  ["ctrl+backspace"] = "serial-monitor:clear-input",
  ["ctrl+v"] = "serial-monitor:paste",
  ["up"] = "serial-monitor:previous-sent",
  ["down"] = "serial-monitor:next-sent",
  ["escape"] = "serial-monitor:leave",
})


return SerialView
