-- Panel of the New Project page to pick the value of one board setting
-- (e.g. Partition Scheme) from all of its values.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "plugins.arduino.ui"

local OptionPanel = {}
OptionPanel.__index = OptionPanel

---@param view arduino.newprojectview
---@param option arduino.board_option
function OptionPanel.new(view, option)
  local panel = setmetatable({ view = view, option = option, filter = "", selected = 1, first_row = 1 }, OptionPanel)
  local current = view:option_value(option)
  for i, item in ipairs(panel:get_list()) do
    if item.key == current then panel.selected = i end
  end
  return panel
end


function OptionPanel:get_list()
  local needle = self.filter:lower()
  local current = self.view:option_value(self.option)
  local list = {}
  for _, value in ipairs(self.option.values) do
    local detail = value.value == self.option.default and "default" or nil
    if value.value == current then detail = detail and "current, default" or "current" end
    local item = { key = value.value, label = value.label, detail = detail }
    if needle == "" or (value.label .. " " .. value.value):lower():find(needle, 1, true) then
      table.insert(list, item)
    end
  end
  return list
end


function OptionPanel:choose()
  local item = self:get_list()[self.selected]
  if not item then return end
  self.view:set_option_value(self.option, item.key)
  self.view:close_panel()
end


-------------------------------------------------------------------------------
-- Panel interface used by the New Project page
-------------------------------------------------------------------------------

function OptionPanel:buttons()
  return {
    back = { text = "←  Back", run = function() self.view:close_panel() end },
    next = { text = "Use This", run = function() self:choose() end, enabled = self:get_list()[self.selected] ~= nil },
    hint = "Type to search    Enter: use    Esc: back",
  }
end

function OptionPanel:enter() self:choose() end

function OptionPanel:escape()
  if self.filter ~= "" then
    self.filter, self.selected, self.first_row = "", 1, 1
    core.redraw = true
  else
    self.view:close_panel()
  end
end

function OptionPanel:backspace()
  if self.filter ~= "" then
    self.filter = ui.remove_last_char(self.filter)
    self.selected, self.first_row = 1, 1
    core.redraw = true
  end
end

function OptionPanel:text_input(text)
  self.filter = self.filter .. text:gsub("[\r\n]", "")
  self.selected, self.first_row = 1, 1
  core.redraw = true
end

function OptionPanel:wants_text() return true end

function OptionPanel:move(delta)
  local count = #self:get_list()
  if count == 0 then return end
  self.selected = common.clamp(self.selected + delta, 1, count)
  local rows = self.visible_rows or 1
  if self.selected < self.first_row then
    self.first_row = self.selected
  elseif self.selected >= self.first_row + rows then
    self.first_row = self.selected - rows + 1
  end
  core.redraw = true
end

function OptionPanel:wheel(dy)
  local rows = self.visible_rows or 1
  self.first_row = common.clamp(self.first_row - (dy > 0 and 3 or -3), 1, math.max(1, #self:get_list() - rows + 1))
  core.redraw = true
end


function OptionPanel:layout(rect, add_target)
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local row_h = font:get_height() + pad_y
  local L = {}
  L.intro_y = rect.y + pad_y
  L.box = { x = rect.x + pad_x, y = L.intro_y + (font:get_height() + pad_y / 2) * 2 + pad_y,
    w = rect.w - pad_x * 2, h = font:get_height() + pad_y * 2 }
  local list_y = L.box.y + L.box.h + pad_y
  local list_h = math.max(row_h, rect.y + rect.h - list_y - pad_y)
  self.visible_rows = math.max(1, math.floor(list_h / row_h))
  local items = self:get_list()
  self.first_row = common.clamp(self.first_row, 1, math.max(1, #items - self.visible_rows + 1))
  L.rows = {}
  for i = self.first_row, math.min(#items, self.first_row + self.visible_rows - 1) do
    local row = { item = items[i], index = i, id = "value:" .. items[i].key,
      x = rect.x + pad_x, y = list_y + (i - self.first_row) * row_h, w = rect.w - pad_x * 2, h = row_h }
    table.insert(L.rows, row)
    add_target(row.id, row.x, row.y, row.w, row.h, function(clicks)
      self.selected = i
      if clicks and clicks >= 2 then self:choose() end
      core.redraw = true
    end)
  end
  L.list_y, L.row_h = list_y, row_h
  self.current_layout = L
end


function OptionPanel:draw(rect, hovered_id)
  local L = self.current_layout
  if not L then return end
  local pad_x = style.padding.x
  renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, style.background2)
  core.push_clip_rect(rect.x, rect.y, rect.w, rect.h)
  local W = ui.writer(rect.x + pad_x, L.intro_y, rect.w - pad_x * 2)
  W.paragraph(self.option.label, style.accent)
  W.paragraph(#self.option.values .. " choices. Setting name in the fqbn: " .. self.option.option, style.dim)
  ui.draw_text_box(L.box, self.filter, "Type to search", core.active_view == self.view)
  ui.draw_rows(L.rows, self.selected, hovered_id)
  if #L.rows == 0 then
    common.draw_text(style.font, style.dim, "Nothing matches \"" .. self.filter .. "\"", "left",
      rect.x + pad_x * 2, L.list_y, 0, L.row_h)
  end
  core.pop_clip_rect()
end


return OptionPanel
