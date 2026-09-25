local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---Welcome screen shown in nodes without any open document.
---@class core.emptyview : core.view
---@field super core.view
local EmptyView = View:extend()

function EmptyView:__tostring() return "EmptyView" end

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

  local actions = {}
  for _, action in ipairs(self.actions) do
    if command.is_valid(action.cmd) then table.insert(actions, action) end
  end

  -- drop recent folders that do not fit in the view
  local fixed_h = title_h + section_gap + header_h + #actions * row_h + section_gap + header_h
  local max_rows = math.max(1, math.floor((self.size.y - fixed_h - pad_y * 2) / row_h))
  local recent_count = math.min(#self.recents, max_rows)
  local content_h = fixed_h + math.max(recent_count, 1) * row_h

  local w = math.min(self.size.x - pad_x * 4, math.floor(560 * SCALE))
  local x = self.position.x + math.floor((self.size.x - w) / 2)
  local y = self.position.y + math.max(pad_y, math.floor((self.size.y - content_h) / 2))

  local layout = { x = x, w = w, row_h = row_h }
  layout.title_y = y
  y = y + title_h + section_gap

  layout.start_y = y
  y = y + header_h
  local items = {}
  for _, action in ipairs(actions) do
    local binding = keymap.get_binding(action.cmd)
    table.insert(items, {
      id = "action:" .. action.cmd,
      x = x, y = y, w = w, h = row_h,
      label = action.label,
      detail = binding and format_binding(binding),
      detail_align = "right",
      run = function() command.perform(action.cmd) end,
    })
    y = y + row_h
  end
  y = y + section_gap

  layout.recent_y = y
  y = y + header_h
  layout.no_recents_y = recent_count == 0 and y or nil
  for i = 1, recent_count do
    local path = self.recents[i]
    table.insert(items, {
      id = "recent:" .. path,
      x = x, y = y, w = w, h = row_h,
      label = common.basename(path),
      detail = common.home_encode(common.dirname(path) or path),
      detail_align = "left",
      run = function() open_folder(path) end,
    })
    y = y + row_h
  end

  layout.items = items
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
    if x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then
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
  local label_end = common.draw_text(style.font, style.accent, item.label, "left", text_x, item.y, 0, item.h)
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

  common.draw_text(style.font, style.dim, "Start", "left", x, layout.start_y, w, header_h)
  common.draw_text(style.font, style.dim, "Recent", "left", x, layout.recent_y, w, header_h)
  if layout.no_recents_y then
    common.draw_text(style.font, style.dim, "No recent folders", "left",
      x + style.padding.x, layout.no_recents_y, w, layout.row_h)
  end

  for _, item in ipairs(layout.items) do
    self:draw_item(item)
  end
end

return EmptyView
