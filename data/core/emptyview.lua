local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---Welcome screen shown in nodes without any open document.
---
---The screen is made of sections (see `EmptyView.add_section`), each with a
---title and a list of rows. Plugins can add their own sections.
---@class core.emptyview : core.view
---@field super core.view
local EmptyView = View:extend()

function EmptyView:__tostring() return "EmptyView" end

---A row on the welcome screen.
---@class core.emptyview.item
---@field id string Unique and stable across frames; used to track hovering.
---@field label string
---@field detail? string Secondary text.
---@field detail_align? "left"|"right" "right" aligns the detail to the right edge (e.g. shortcuts), "left" puts it after the label, shortening it like a path when too long.
---@field color? renderer.color Label color; defaults to `style.accent` for clickable rows and `style.text` otherwise.
---@field run? fun() Called when the row is clicked; rows without it are not clickable.

---A section of the welcome screen.
---@class core.emptyview.section
---@field id string
---@field title string
---@field order number Sections are shown by ascending order.
---@field get_items fun(view: core.emptyview): core.emptyview.item[]
---@field fill? boolean Show only as many rows as fit in the remaining space.
---@field empty_text? string Shown when the section has no rows.

---@type core.emptyview.section[]
EmptyView.sections = {}

---Adds a section to the welcome screen, replacing any section with the same id.
---@param section core.emptyview.section
function EmptyView.add_section(section)
  for i, other in ipairs(EmptyView.sections) do
    if other.id == section.id then table.remove(EmptyView.sections, i) break end
  end
  table.insert(EmptyView.sections, section)
  table.sort(EmptyView.sections, function(a, b) return a.order < b.order end)
  core.redraw = true
end

---Actions listed under "Start"; hidden when the command is not currently valid.
EmptyView.actions = {
  { label = "New File", cmd = "core:new-doc" },
  { label = "Open File...", cmd = "core:open-file" },
  { label = "Open Folder...", cmd = "core:change-project-folder" },
  { label = "Command Palette", cmd = "core:find-command" },
}

---Maximum number of recent folders listed.
EmptyView.max_recents = 8

-- how often (in seconds) to re-check which recent folders still exist
local RECENTS_CHECK_INTERVAL = 1


function EmptyView:new()
  EmptyView.super.new(self)
  self.hovered_id = nil
  self.items = {}
  self.recents = {}
  self.recents_checked_at = -math.huge
end


function EmptyView:get_name()
  return "Welcome"
end


function EmptyView:get_filename()
  return ""
end


---Shortens a path to fit in max_w by replacing middle folders with an ellipsis,
---keeping the first component and as many trailing folders as fit.
local function shorten_path(font, path, max_w)
  if font:get_width(path) <= max_w then return path end
  local ellipsis = "\u{2026}"
  local head = path:match("^[/\\]?[^/\\]*")
  local sep = path:match("[/\\]") or PATHSEP
  local parts = {}
  for part in path:sub(#head + 1):gmatch("[^/\\]+") do table.insert(parts, part) end
  local best, suffix = nil, ""
  for i = #parts, 1, -1 do
    suffix = sep .. parts[i] .. suffix
    local text = head .. sep .. ellipsis .. suffix
    if font:get_width(text) > max_w then break end
    best = text
  end
  if best then return best end
  -- not even the last folder fits after the head: trim characters from the left,
  -- starting only at UTF-8 character boundaries
  for i = 2, #path do
    local byte = path:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      local text = ellipsis .. path:sub(i)
      if font:get_width(text) <= max_w then return text end
    end
  end
  return ellipsis
end


local function format_binding(binding)
  return (binding:gsub("[^+]+", function(key)
    return key:sub(1, 1):upper() .. key:sub(2)
  end))
end


local function open_folder(path)
  local project = core.root_project()
  if project and project.path == path then return end
  core.confirm_close_docs(core.docs, core.open_project, path)
end


function EmptyView:update_recents()
  local now = system.get_time()
  if now - self.recents_checked_at < RECENTS_CHECK_INTERVAL then return end
  self.recents_checked_at = now
  local project = core.root_project()
  local recents = {}
  for _, path in ipairs(core.recent_projects or {}) do
    if #recents >= self.max_recents then break end
    local info = system.get_file_info(path)
    if info and info.type == "dir" and not (project and project.path == path) then
      table.insert(recents, path)
    end
  end
  self.recents = recents
end


---Recomputes the position of everything drawn on the welcome screen.
function EmptyView:layout()
  local font, big_font = style.font, style.big_font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local row_h = font:get_height() + pad_y
  local title_h = big_font:get_height()
  local header_h = font:get_height() + pad_y
  local section_gap = pad_y * 2

  -- gather rows and measure everything except the rows of "fill" sections
  local sections = {}
  local fixed_h = title_h
  local fill_count = 0
  for _, section in ipairs(self.sections) do
    local rows = section.get_items(self) or {}
    table.insert(sections, { section = section, rows = rows })
    fixed_h = fixed_h + section_gap + header_h
    if section.fill then
      fill_count = fill_count + 1
    elseif #rows > 0 or section.empty_text then
      fixed_h = fixed_h + math.max(#rows, 1) * row_h
    end
  end

  -- "fill" sections share the remaining space, keeping at least one row each
  local free_rows = math.floor((self.size.y - fixed_h - pad_y * 2) / row_h)
  local fill_rows = fill_count > 0 and math.max(1, math.floor(free_rows / fill_count)) or 0
  local content_h = fixed_h
  for _, s in ipairs(sections) do
    if s.section.fill then
      while #s.rows > fill_rows do table.remove(s.rows) end
      if #s.rows > 0 or s.section.empty_text then
        content_h = content_h + math.max(#s.rows, 1) * row_h
      end
    end
  end

  local w = math.min(self.size.x - pad_x * 4, math.floor(560 * SCALE))
  local x = self.position.x + math.floor((self.size.x - w) / 2)
  local y = self.position.y + math.max(pad_y, math.floor((self.size.y - content_h) / 2))

  local layout = { x = x, w = w, row_h = row_h, header_h = header_h, headers = {}, notes = {}, items = {} }
  layout.title_y = y
  y = y + title_h

  for _, s in ipairs(sections) do
    y = y + section_gap
    table.insert(layout.headers, { text = s.section.title, y = y })
    y = y + header_h
    if #s.rows == 0 and s.section.empty_text then
      table.insert(layout.notes, { text = s.section.empty_text, y = y })
      y = y + row_h
    end
    for _, row in ipairs(s.rows) do
      row.x, row.y, row.w, row.h = x, y, w, row_h
      table.insert(layout.items, row)
      y = y + row_h
    end
  end

  return layout
end


function EmptyView:update()
  EmptyView.super.update(self)
  self:update_recents()
  self.current_layout = self:layout()
  self.items = self.current_layout.items
end


function EmptyView:get_item_at(x, y)
  for _, item in ipairs(self.items) do
    if item.run and x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then
      return item
    end
  end
end


function EmptyView:set_hovered_item(item)
  local id = item and item.id
  if self.hovered_id ~= id then
    self.hovered_id = id
    self.cursor = item and "hand" or "arrow"
    core.redraw = true
  end
end


function EmptyView:on_mouse_moved(x, y, dx, dy)
  EmptyView.super.on_mouse_moved(self, x, y, dx, dy)
  self:set_hovered_item(self:get_item_at(x, y))
end


function EmptyView:on_mouse_left()
  EmptyView.super.on_mouse_left(self)
  self:set_hovered_item(nil)
end


function EmptyView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return end
  local item = self:get_item_at(x, y)
  if item then
    item.run()
    return true
  end
end


function EmptyView:draw_item(item)
  local x, w = item.x, item.w
  local text_x = x + style.padding.x
  if item.id == self.hovered_id then
    renderer.draw_rect(x, item.y, w, item.h, style.line_highlight)
  end
  core.push_clip_rect(x, item.y, w - style.padding.x, item.h)
  local color = item.color or (item.run and style.accent or style.text)
  local label_end = common.draw_text(style.font, color, item.label, "left", text_x, item.y, 0, item.h)
  if item.detail then
    if item.detail_align == "right" then
      common.draw_text(style.font, style.dim, item.detail, "right", x, item.y, w - style.padding.x, item.h)
    else
      local detail_x = label_end + style.padding.x
      local detail = shorten_path(style.font, item.detail, x + w - style.padding.x - detail_x)
      common.draw_text(style.font, style.dim, detail, "left", detail_x, item.y, 0, item.h)
    end
  end
  core.pop_clip_rect()
end


function EmptyView:draw()
  self:draw_background(style.background)
  local layout = self.current_layout or self:layout()
  local x, w = layout.x, layout.w
  local header_h = style.font:get_height() + style.padding.y

  local title_end = common.draw_text(style.big_font, style.text, "Superduino", "left",
    x, layout.title_y, 0, style.big_font:get_height())
  common.draw_text(style.font, style.dim, VERSION, "left",
    title_end + style.padding.x, layout.title_y, 0, style.big_font:get_height())

  for _, header in ipairs(layout.headers) do
    common.draw_text(style.font, style.dim, header.text, "left", x, header.y, w, layout.header_h)
  end
  for _, note in ipairs(layout.notes) do
    common.draw_text(style.font, style.dim, note.text, "left", x + style.padding.x, note.y, w, layout.row_h)
  end

  for _, item in ipairs(layout.items) do
    self:draw_item(item)
  end
end


EmptyView.add_section({
  id = "start",
  title = "Start",
  order = 10,
  get_items = function()
    local items = {}
    for _, action in ipairs(EmptyView.actions) do
      if command.is_valid(action.cmd) then
        local binding = keymap.get_binding(action.cmd)
        table.insert(items, {
          id = "action:" .. action.cmd,
          label = action.label,
          detail = binding and format_binding(binding),
          detail_align = "right",
          run = function() command.perform(action.cmd) end,
        })
      end
    end
    return items
  end,
})

EmptyView.add_section({
  id = "recent",
  title = "Recent",
  order = 100,
  fill = true,
  empty_text = "No recent folders",
  get_items = function(view)
    local items = {}
    for _, path in ipairs(view.recents) do
      table.insert(items, {
        id = "recent:" .. path,
        label = common.basename(path),
        detail = common.home_encode(common.dirname(path) or path),
        detail_align = "left",
        run = function() open_folder(path) end,
      })
    end
    return items
  end,
})

return EmptyView
