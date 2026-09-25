-- Panel of the New Project page to pick an optional template for the sketch.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local project = require "plugins.arduino.project"
local ui = require "plugins.arduino.ui"

local TemplatesPanel = {}
TemplatesPanel.__index = TemplatesPanel

function TemplatesPanel.new(view, board)
  local panel = setmetatable({ view = view, board = board, filter = "", selected = 1, first_row = 1,
    examples = nil, loading = true }, TemplatesPanel)
  panel.builtin = project.builtin_templates()
  core.add_thread(function()
    local examples, err = project.load_examples(board.fqbn)
    panel.examples, panel.examples_error, panel.loading = examples or {}, err, false
    panel:select_current()
    core.redraw = true
  end)
  panel:select_current()
  return panel
end


local function item_for(template)
  local detail = template.kind == "builtin" and "Superduino starter"
    or template.kind == "example" and ("library: " .. template.group) or "default"
  return { key = template.kind .. ":" .. (template.path or ""), label = template.name, note = template.description,
    detail = detail, template = template }
end


function TemplatesPanel:all_items()
  local items = { item_for(project.EMPTY_TEMPLATE) }
  for _, t in ipairs(self.builtin) do table.insert(items, item_for(t)) end
  for _, t in ipairs(self.examples or {}) do table.insert(items, item_for(t)) end
  return items
end


function TemplatesPanel:get_list()
  local needle = self.filter:lower()
  if needle == "" then return self:all_items() end
  local list = {}
  for _, item in ipairs(self:all_items()) do
    local text = (item.label .. " " .. item.note .. " " .. item.detail):lower()
    if text:find(needle, 1, true) then table.insert(list, item) end
  end
  return list
end


-- Selects the template currently chosen on the page.
function TemplatesPanel:select_current()
  local current = self.view.template or project.EMPTY_TEMPLATE
  local key = current.kind .. ":" .. (current.path or "")
  for i, item in ipairs(self:get_list()) do
    if item.key == key then self.selected = i return end
  end
end


function TemplatesPanel:choose()
  local item = self:get_list()[self.selected]
  if not item then return end
  self.view.template = item.template.kind ~= "empty" and item.template or nil
  self.view:close_panel()
end


-------------------------------------------------------------------------------
-- Panel interface used by the New Project page
-------------------------------------------------------------------------------

function TemplatesPanel:buttons()
  return {
    back = { text = "←  Back", run = function() self.view:close_panel() end },
    next = { text = "Use Template", run = function() self:choose() end, enabled = self:get_list()[self.selected] ~= nil },
    hint = "Type to search    Enter: use",
  }
end

function TemplatesPanel:enter() self:choose() end

function TemplatesPanel:escape()
  if self.filter ~= "" then
    self.filter, self.selected, self.first_row = "", 1, 1
    core.redraw = true
  else
    self.view:close_panel()
  end
end

function TemplatesPanel:backspace()
  if self.filter ~= "" then
    self.filter = ui.remove_last_char(self.filter)
    self.selected, self.first_row = 1, 1
    core.redraw = true
  else
    self.view:close_panel()
  end
end

function TemplatesPanel:text_input(text)
  self.filter = self.filter .. text:gsub("[\r\n]", "")
  self.selected, self.first_row = 1, 1
  core.redraw = true
end

function TemplatesPanel:wants_text() return true end

function TemplatesPanel:move(delta)
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

function TemplatesPanel:wheel(dy)
  local rows = self.visible_rows or 1
  self.first_row = common.clamp(self.first_row - (dy > 0 and 3 or -3), 1, math.max(1, #self:get_list() - rows + 1))
  core.redraw = true
end


function TemplatesPanel:layout(rect, add_target)
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
    local row = { item = items[i], index = i, id = "template:" .. items[i].key,
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


function TemplatesPanel:draw(rect, hovered_id)
  local L = self.current_layout
  if not L then return end
  local pad_x = style.padding.x
  renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, style.background2)
  core.push_clip_rect(rect.x, rect.y, rect.w, rect.h)
  local W = ui.writer(rect.x + pad_x, L.intro_y, rect.w - pad_x * 2)
  W.paragraph("Choose a template (optional)", style.accent)
  local status = self.loading and "Loading examples..." or
    (self.examples_error and ("Examples could not be loaded: " .. self.examples_error)
      or (#self.examples .. " library examples for " .. self.board.name .. "."))
  W.paragraph("Start from an empty sketch, a Superduino starter, or an example. " .. status,
    self.examples_error and style.warn or style.dim)
  ui.draw_text_box(L.box, self.filter, "Type to search, e.g. blink or serial", core.active_view == self.view)
  ui.draw_rows(L.rows, self.selected, hovered_id)
  if #L.rows == 0 then
    common.draw_text(style.font, style.dim, "Nothing matches \"" .. self.filter .. "\"", "left",
      rect.x + pad_x * 2, L.list_y, 0, L.row_h)
  end
  core.pop_clip_rect()
end


return TemplatesPanel
