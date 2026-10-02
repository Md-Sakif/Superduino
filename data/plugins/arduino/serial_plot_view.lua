-- The Serial Plotter panel under the editor: the numbers the board prints, as
-- lines over the last samples. It shares the Serial Monitor's connection.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local monitor = require "plugins.arduino.serial_monitor"
local plot = require "plugins.arduino.serial_plot"
local bottom_panels = require "plugins.arduino.bottom_panels"
local BuildPanel = require "plugins.arduino.build_panel"
local SerialView = require "plugins.arduino.serial_view"
local ui = require "plugins.arduino.ui"

---@class arduino.serialplotview : core.view
local PlotView = View:extend()

function PlotView:__tostring() return "PlotView" end

PlotView.save_in_workspace = false

PlotView.DEFAULT_HEIGHT = 260

---Colors of the series, in order of appearance (distinct on dark and light themes).
PlotView.PALETTE = {
  { common.color "#4e9de6" }, { common.color "#e8913a" }, { common.color "#5bbf6a" }, { common.color "#e05561" },
  { common.color "#a77fe0" }, { common.color "#d4b83a" }, { common.color "#e07ab8" }, { common.color "#45c2c2" },
}


function PlotView:new()
  PlotView.super.new(self)
  self.visible = false
  self.target_height = PlotView.DEFAULT_HEIGHT * SCALE
  self.hovered_id = nil
  self.targets = {}
end


function PlotView:get_name() return "Serial Plotter" end


function PlotView:set_target_size(axis, value)
  if axis ~= "y" then return false end
  self.target_height = math.max(value, self:header_height() * 4)
  return true
end


function PlotView:header_height()
  return style.font:get_height() + style.padding.y * 2
end


function PlotView:show()
  bottom_panels.showing("plotter")
  if not self.visible then
    self.visible = true
    core.redraw = true
    -- like the Serial Monitor: opening the plotter connects
    if monitor.state() == "disconnected" and SerialView.target() then SerialView.connect() end
  end
end


function PlotView:hide()
  self.visible = false
  core.redraw = true
end


function PlotView.color(series)
  return PlotView.PALETTE[(series.color - 1) % #PlotView.PALETTE + 1]
end


---Lets the user choose how many of the last samples are shown.
function PlotView.choose_window()
  local current = plot.window()
  local items = {}
  for _, n in ipairs(plot.WINDOWS) do
    table.insert(items, { text = tostring(n), info = n == current and "current" or nil })
  end
  core.command_view:enter("Points Shown", {
    submit = function(text, item)
      local n = tonumber(item and item.text or text)
      if n and n >= 2 then plot.set_window(math.min(math.floor(n), plot.MAX_SAMPLES)) end
    end,
    suggest = function(text)
      local list = {}
      for _, item in ipairs(items) do
        if item.text:find(text, 1, true) then table.insert(list, item) end
      end
      return list
    end,
    validate = function(text, item) return item ~= nil or (tonumber(text) or 0) >= 2 end,
  })
end


function PlotView:update()
  local dest = self.visible and self.target_height or 0
  self:move_towards(self.size, "y", dest, nil, "plotter")
  PlotView.super.update(self)
  self:layout()
end


---Title of the header and its color.
function PlotView:title()
  local text, color = SerialView.state_text()
  return "Serial Plotter: " .. text, color
end


-- A step of 1, 2 or 5 times a power of ten giving about `count` steps over `range`.
local function nice_step(range, count)
  local raw = range / count
  local power = 10 ^ math.floor(math.log(raw, 10))
  for _, m in ipairs({ 1, 2, 5, 10 }) do
    if raw <= m * power then return m * power end
  end
  return 10 * power
end


local function format_number(v, step)
  local decimals = math.max(0, -math.floor(math.log(step, 10) + 1e-9))
  return string.format("%." .. math.min(decimals, 6) .. "f", v)
end


---The shown value range with round limits and the step between grid lines.
local function axis(height_px)
  local low, high = plot.bounds()
  if not low then return nil end
  if low == high then low, high = low - 1, high + 1 end
  local lines = math.max(2, math.floor(height_px / (style.font:get_height() * 2.5)))
  local step = nice_step(high - low, lines)
  return math.floor(low / step) * step, math.ceil(high / step) * step, step
end


-- Clickable areas, the legend and the plot area (in screen coordinates).
function PlotView:layout()
  self.targets = {}
  local font, pad_x, pad_y = style.font, style.padding.x, style.padding.y
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local header_h = self:header_height()
  local state = monitor.state()
  local sketch = BuildPanel.sketch()
  local baud = sketch and monitor.baud_for(sketch.dir)
  if monitor.session then baud = monitor.session.baud end
  local paused = plot.paused_at ~= nil

  -- header links, right to left
  local right = x + w - pad_x
  self.links = {}
  for _, link in ipairs({
    { id = "plot:hide", text = "Hide", run = function() self:hide() end },
    { id = "plot:clear", text = "Clear", run = plot.clear, enabled = #plot.series > 0 },
    { id = "plot:pause", text = paused and "Resume" or "Pause", on = paused,
      run = function() plot.set_paused(not paused) end },
    { id = "plot:window", text = plot.window() .. " points", run = PlotView.choose_window },
    state ~= "disconnected" and { id = "plot:disconnect", text = "Disconnect", run = function() monitor.disconnect() end }
      or { id = "plot:connect", text = "Connect", run = SerialView.connect, enabled = sketch ~= nil },
    { id = "plot:baud", text = (baud or monitor.DEFAULT_BAUD) .. " baud", run = SerialView.choose_baud,
      enabled = sketch ~= nil },
  }) do
    local lw = font:get_width(link.text) + pad_x
    link.x, link.y, link.w, link.h = right - lw, y, lw, header_h
    right = right - lw
    if link.enabled ~= false then table.insert(self.targets, link) end
    table.insert(self.links, link)
  end
  self.title_w = right - x - pad_x * 2

  -- the legend: a swatch, the name and the latest value of each series; a click hides it
  local legend_h = font:get_height() + pad_y
  local lx, ly = x + pad_x, y + header_h + pad_y / 2
  self.legend = {}
  for i, series in ipairs(plot.series) do
    local text = series.name .. (series.last and ("  " .. format_number(series.last, 0.001):gsub("%.?0+$", "")) or "")
    local iw = font:get_height() * 0.6 + pad_x / 2 + font:get_width(text) + pad_x * 1.5
    if lx + iw > x + w - pad_x and lx > x + pad_x then
      lx, ly = x + pad_x, ly + legend_h
    end
    local item = { id = "series:" .. i, series = series, text = text, x = lx, y = ly, w = iw, h = legend_h,
      run = function()
        series.hidden = not series.hidden
        core.redraw = true
      end }
    table.insert(self.legend, item)
    table.insert(self.targets, item)
    lx = lx + iw
  end
  local legend_bottom = #plot.series > 0 and (ly + legend_h + pad_y / 2) or (y + header_h)

  -- the plot area, with room for the value labels on the left and the sample numbers below
  local low, high, step = axis(math.max(1, y + h - legend_bottom - legend_h * 2))
  local label_w = 0
  if low then
    for v = low, high + step / 2, step do label_w = math.max(label_w, font:get_width(format_number(v, step))) end
  end
  self.area = { x = x + pad_x + label_w + pad_x / 2, y = legend_bottom + pad_y, low = low, high = high, step = step }
  self.area.w = math.max(1, x + w - pad_x * 2 - self.area.x)
  self.area.h = math.max(1, y + h - legend_h - pad_y - self.area.y)
end


function PlotView:target_at(x, y)
  for _, target in ipairs(self.targets) do
    if x >= target.x and x < target.x + target.w and y >= target.y and y < target.y + target.h then return target end
  end
end


function PlotView:on_mouse_moved(x, y, ...)
  PlotView.super.on_mouse_moved(self, x, y, ...)
  local target = self:target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = target and "hand" or "arrow"
end


function PlotView:on_mouse_left()
  PlotView.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function PlotView:on_mouse_pressed(button, x, y, clicks)
  local target = button == "left" and self:target_at(x, y)
  if target then target.run() end
  return true
end


---Draws one series as a line of thin rectangles, one per pixel column (the
---renderer only draws rectangles); with more samples than pixels, a column
---covers the range of its samples. Missing values break the line.
local function draw_series(series, area, first, last, color)
  local thickness = math.max(1, math.floor(SCALE * 2 + 0.5))
  local span = math.max(1, last - first)
  local range = area.high - area.low
  local function px(i) return area.x + (i - first) / span * area.w end
  local function py(v) return area.y + area.h - (v - area.low) / range * area.h end
  local columns = {} -- column -> { top, bottom }
  local function cover(col, y1, y2)
    local c = columns[col]
    local top, bottom = math.min(y1, y2), math.max(y1, y2)
    if c then
      c[1], c[2] = math.min(c[1], top), math.max(c[2], bottom)
    else
      columns[col] = { top, bottom }
    end
  end
  local prev_x, prev_y
  for i = first, last do
    local v = series.values[i]
    if v then
      local cx, cy = px(i), py(v)
      if prev_x then
        -- the segment from the previous sample, column by column
        local c1, c2 = math.floor(prev_x), math.floor(cx)
        for col = c1, c2 do
          local t1 = c2 == c1 and 0 or common.clamp((col - prev_x) / (cx - prev_x), 0, 1)
          local t2 = c2 == c1 and 1 or common.clamp((col + 1 - prev_x) / (cx - prev_x), 0, 1)
          cover(col, prev_y + (cy - prev_y) * t1, prev_y + (cy - prev_y) * t2)
        end
      else
        cover(math.floor(cx), cy, cy)
      end
      prev_x, prev_y = cx, cy
    else
      prev_x, prev_y = nil, nil
    end
  end
  local half = thickness / 2
  for col, c in pairs(columns) do
    renderer.draw_rect(col, c[1] - half, math.max(1, math.floor(thickness / 2 + 0.5)), c[2] - c[1] + thickness, color)
  end
end


function PlotView:draw()
  if self.size.y < 1 then return end
  self:layout()
  self:draw_background(style.background)
  local font, pad_x = style.font, style.padding.x
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local header_h = self:header_height()
  core.push_clip_rect(x, y, w, h)

  -- legend
  for _, item in ipairs(self.legend) do
    local hovered = self.hovered_id == item.id
    local hidden = item.series.hidden
    local sw = math.floor(font:get_height() * 0.6)
    local color = PlotView.color(item.series)
    if hidden then
      ui.draw_border(item.x, item.y + (item.h - sw) / 2, sw, sw, style.dim)
    else
      renderer.draw_rect(item.x, item.y + (item.h - sw) / 2, sw, sw, color)
    end
    common.draw_text(font, hovered and style.accent or (hidden and style.dim or style.text), item.text, "left",
      item.x + sw + pad_x / 2, item.y, 0, item.h)
  end

  local area = self.area
  if #plot.series == 0 then
    local lines = {
      "Print numbers, one sample per line, to plot them. For example:",
      "  Serial.println(analogRead(A0));",
      "Several values on a line (spaces or commas between them) make several lines; label them like this:",
      "  Serial.print(\"temp:\"); Serial.print(t); Serial.print(\" hum:\"); Serial.println(h);",
    }
    local ty = y + header_h + style.padding.y
    for i, line in ipairs(lines) do
      local f = line:sub(1, 2) == "  " and style.code_font or font
      common.draw_text(f, style.dim, line, "left", x + pad_x, ty, 0, font:get_height() + style.padding.y / 2)
      ty = ty + font:get_height() + style.padding.y / 2
    end
  elseif area.low then
    local first, last = plot.range()
    -- grid with the values on the left
    local grid_h = math.max(1, math.floor(SCALE))
    for v = area.low, area.high + area.step / 2, area.step do
      local gy = math.floor(area.y + area.h - (v - area.low) / (area.high - area.low) * area.h)
      renderer.draw_rect(area.x, gy, area.w, grid_h, style.line_highlight)
      common.draw_text(font, style.dim, format_number(v, area.step), "right", x + pad_x, gy - font:get_height() / 2,
        area.x - pad_x / 2 - x - pad_x, font:get_height())
    end
    -- the sample numbers of both ends
    local by = area.y + area.h + style.padding.y / 2
    common.draw_text(font, style.dim, tostring(first), "left", area.x, by, 0, font:get_height())
    common.draw_text(font, style.dim, tostring(last), "right", area.x, by, area.w, font:get_height())
    core.push_clip_rect(area.x, area.y - 2, area.w + 2, area.h + 4)
    for _, series in ipairs(plot.series) do
      if not series.hidden then draw_series(series, area, first, last, PlotView.color(series)) end
    end
    core.pop_clip_rect()
  else
    common.draw_text(font, style.dim, "All lines are hidden; click a name above to show it.", "left", area.x, area.y, 0,
      font:get_height())
  end

  -- header
  renderer.draw_rect(x, y, w, header_h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  local title, color = self:title()
  common.draw_text(font, color, ui.truncate(font, title, self.title_w or w), "left", x + pad_x, y, 0, header_h)
  for _, link in ipairs(self.links or {}) do
    local hovered = self.hovered_id == link.id
    local link_color = link.enabled == false and style.dim
      or (hovered and style.accent or (link.on and style.accent or style.text))
    common.draw_text(font, link_color, link.text, "center", link.x, link.y, link.w, link.h)
  end
  core.pop_clip_rect()
end


---The panel, added under the editor the first time it is needed.
---@return arduino.serialplotview
function PlotView.get()
  if not PlotView.view then
    PlotView.view = PlotView()
    local node = core.root_view:get_primary_node()
    node:split("down", PlotView.view, { y = true }, true)
  end
  return PlotView.view
end


function PlotView.is_open()
  return PlotView.view ~= nil and PlotView.view.visible
end


bottom_panels.add({ id = "plotter", is_open = PlotView.is_open, close = function() PlotView.view:hide() end,
  show = function() PlotView.get():show() end })


command.add(nil, {
  ["arduino:toggle-serial-plotter"] = function()
    if PlotView.is_open() then PlotView.view:hide() else PlotView.get():show() end
  end,
  ["arduino:show-serial-plotter"] = function() PlotView.get():show() end,
  ["arduino:serial-plotter-clear"] = plot.clear,
  ["arduino:serial-plotter-points"] = PlotView.choose_window,
})

command.add(function() return #plot.series > 0 end, {
  ["arduino:serial-plotter-pause"] = function() plot.set_paused(plot.paused_at == nil) end,
})


return PlotView
