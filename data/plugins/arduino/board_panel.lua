-- The Board panel in the left side pane, under the file tree: the open sketch's
-- vendor, family and board (clicking one opens Board Settings on its step), and its
-- changed settings with a Change Configuration link.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local cli = require "plugins.arduino.cli"
local project = require "plugins.arduino.project"
local ui = require "plugins.arduino.ui"
local NewProjectView = require "plugins.arduino.newprojectview"

---@class arduino.boardpanel : core.view
local BoardPanel = View:extend()

function BoardPanel:__tostring() return "BoardPanel" end

BoardPanel.save_in_workspace = false


-------------------------------------------------------------------------------
-- The open sketch
-------------------------------------------------------------------------------

-- what is shown for the open project; re-read when sketch.yaml changes
local current = { dir = nil, checked = 0 }
-- the installed boards by board fqbn, and their settings (for their labels)
-- by board fqbn; boards are loaded again when sketch.yaml changes, e.g. after
-- choosing a board of a newly installed family
local boards, boards_state = {}, "unloaded"
local settings = {}


local function load_boards()
  if boards_state ~= "unloaded" then return end
  boards_state = "loading"
  core.add_thread(function()
    local loaded = {}
    for _, board in ipairs(project.load_boards() or {}) do loaded[board.fqbn] = board end
    boards, boards_state = loaded, "loaded"
    core.redraw = true
  end)
end


local function load_settings(base)
  if settings[base] ~= nil then return end
  settings[base] = "loading"
  core.add_thread(function()
    settings[base] = project.load_board_options(base) or "failed"
    core.redraw = true
  end)
end


---The open sketch and its board, re-read at most once a second; nil when the
---open project is not an Arduino sketch.
---@return { dir: string, fqbn?: string, profile?: string, error?: string }?
function BoardPanel.current()
  local root = core.root_project()
  local dir = root and root.path
  local now = system.get_time()
  if dir == current.dir and now - current.checked < 1 then return current.info end
  local path = dir and project.sketch_file(dir)
  local info = path and system.get_file_info(path)
  local stamp = info and (info.modified .. ":" .. info.size) or "none"
  current.checked = now
  if dir == current.dir and stamp == current.stamp then return current.info end
  current.dir, current.stamp, current.info = dir, stamp, nil
  if boards_state == "loaded" then boards_state = "unloaded" end
  if dir and project.is_sketch(dir) then
    local sketch, err = project.read_sketch(dir)
    current.info = { dir = dir, error = err }
    if sketch and sketch.profile then
      current.info.fqbn, current.info.profile = sketch.profile.fqbn, sketch.profile.name
    end
  end
  return current.info
end


---What the panel shows, or nil when the open project is not a sketch:
---{ rows = { { label, value, step } }, settings = { text, color }[], has_options?, message?, message_color? }
---`step` is the Board Settings step that changes the row.
function BoardPanel.describe()
  local info = BoardPanel.current()
  if not info then return nil end
  if info.error then
    return { message = "sketch.yaml cannot be read: " .. info.error, message_color = style.error, rows = {}, settings = {} }
  end
  if not info.fqbn then
    return { message = "No board chosen yet.", message_color = style.warn, rows = {}, settings = {} }
  end
  load_boards()
  local base, chosen = project.split_fqbn(info.fqbn)
  local vendor, arch = base:match("^([^:]+):([^:]+):")
  local board = boards[base]
  local result = {
    rows = {
      { label = "Vendor", value = board and board.vendor_name or vendor or "?", step = 1 },
      { label = "Family", value = board and board.arch_name or arch or "?", step = 2 },
      { label = "Board", value = board and board.name or base, step = 3 },
    },
    settings = {},
  }
  if boards_state == "loaded" and not board then
    result.message, result.message_color = "Not installed on this computer.", style.warn
  end
  if board then
    load_settings(base)
    local known = type(settings[base]) == "table" and settings[base] or {}
    result.options_known = type(settings[base]) == "table"
    result.has_options = #known > 0
    for _, option in ipairs(known) do
      local value = chosen[option.option]
      if value then
        local label = value
        for _, entry in ipairs(option.values) do
          if entry.value == value then label = entry.label end
        end
        table.insert(result.settings, { option.label .. ": " .. label, style.text })
      end
    end
  end
  -- settings the board does not know, or not loaded yet
  local known_keys = {}
  for _, option in ipairs(type(settings[base]) == "table" and settings[base] or {}) do known_keys[option.option] = true end
  local rest = {}
  for key, value in pairs(chosen) do
    if not known_keys[key] then table.insert(rest, key .. "=" .. value) end
  end
  table.sort(rest)
  for _, text in ipairs(rest) do table.insert(result.settings, { text, style.dim }) end
  return result
end


-------------------------------------------------------------------------------
-- The view
-------------------------------------------------------------------------------

function BoardPanel:new()
  BoardPanel.super.new(self)
  self.hovered_id = nil
  self.targets = {}
  self.init_size = true
end


function BoardPanel:line_height()
  return style.font:get_height() + style.padding.y
end


---Opens Board Settings of the open sketch on a step (see `NewProjectView.open_edit`).
function BoardPanel.open_settings(step)
  local info = BoardPanel.current()
  if not info then return end
  if cli.status ~= "ok" then
    core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
    return
  end
  NewProjectView.open_edit(info.dir, step)
end


-- Positions of the rows and buttons, also used for clicks.
function BoardPanel:layout(content)
  local font, pad_x, pad_y = style.font, style.padding.x, style.padding.y
  local line_h = self:line_height()
  local x, w = self.position.x, self.size.x
  local L = { header_y = pad_y, rows = {}, settings = {}, targets = {} }
  local y = pad_y + line_h
  local label_w = 0
  for _, row in ipairs(content.rows) do label_w = math.max(label_w, font:get_width(row.label)) end

  if content.message then
    L.message_y = y
    y = y + line_h
  end
  -- each row is clickable as a whole
  for _, row in ipairs(content.rows) do
    local r = { row = row, id = "change:" .. row.step, y = y, value_x = x + pad_x + label_w + pad_x / 2 }
    table.insert(L.rows, r)
    table.insert(L.targets, { id = r.id, x = x, y = y, w = w, h = line_h,
      run = function() BoardPanel.open_settings(row.step) end })
    y = y + line_h
  end
  for _, line in ipairs(content.settings) do
    table.insert(L.settings, { line = line, y = y })
    y = y + line_h
  end
  -- a link to the board's configuration, or "Set Board..." when there is no board yet
  if #content.rows == 0 or content.has_options then
    L.wide = { id = "change:options", y = y,
      text = #content.rows == 0 and "Set Board..." or "Change Configuration..." }
    table.insert(L.targets, { id = L.wide.id, x = x, y = y, w = w, h = line_h,
      run = function() BoardPanel.open_settings(#content.rows == 0 and 1 or 4) end })
    y = y + line_h
  elseif content.options_known then
    L.no_options_y = y
    y = y + line_h
  end
  L.height = y + pad_y
  return L
end


function BoardPanel:update()
  local content = BoardPanel.describe()
  self.content = content
  self.current_layout = content and self:layout(content)
  local dest = self.current_layout and self.current_layout.height or 0
  if self.init_size then
    self.size.y, self.init_size = dest, nil
  else
    self:move_towards(self.size, "y", dest)
  end
  BoardPanel.super.update(self)
end


function BoardPanel:target_at(x, y)
  local L = self.current_layout
  if not L then return nil end
  -- layout positions are relative to the panel's top
  local ry = y - self.position.y
  for _, target in ipairs(L.targets) do
    if x >= target.x and x < target.x + target.w and ry >= target.y and ry < target.y + target.h then return target end
  end
end


function BoardPanel:on_mouse_moved(x, y, ...)
  BoardPanel.super.on_mouse_moved(self, x, y, ...)
  local target = self:target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = target and "hand" or "arrow"
end


function BoardPanel:on_mouse_left()
  BoardPanel.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function BoardPanel:on_mouse_pressed(button, x, y)
  local target = button == "left" and self:target_at(x, y)
  if target then target.run() end
  return true
end


function BoardPanel:draw()
  local L, content = self.current_layout, self.content
  if self.size.y < 1 or not L then return end
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  core.push_clip_rect(x, y, w, h)
  local font, pad_x = style.font, style.padding.x
  local line_h = self:line_height()
  local function text_at(color, text, tx, ty, max_w)
    common.draw_text(font, color, ui.truncate(font, text, max_w), "left", tx, y + ty, 0, line_h)
  end

  text_at(style.dim, "BOARD", x + pad_x, L.header_y, w)
  if L.message_y then text_at(content.message_color, content.message, x + pad_x, L.message_y, w - pad_x * 2) end
  for _, r in ipairs(L.rows) do
    local hovered = self.hovered_id == r.id
    if hovered then renderer.draw_rect(x, y + r.y, w, line_h, style.line_highlight) end
    text_at(style.dim, r.row.label, x + pad_x, r.y, w)
    text_at(hovered and style.accent or style.text, r.row.value, r.value_x, r.y, x + w - pad_x - r.value_x)
  end
  for _, s in ipairs(L.settings) do
    text_at(s.line[2], s.line[1], x + pad_x, s.y, w - pad_x * 2)
  end
  if L.no_options_y then text_at(style.dim, "This board has no options.", x + pad_x, L.no_options_y, w - pad_x * 2) end
  if L.wide then
    local hovered = self.hovered_id == L.wide.id
    if hovered then renderer.draw_rect(x, y + L.wide.y, w, line_h, style.line_highlight) end
    text_at(hovered and style.accent or style.dim, L.wide.text, x + pad_x, L.wide.y, w - pad_x * 2)
  end
  core.pop_clip_rect()
end


---Adds the panel under the file tree, above its toolbar (once the tree exists).
function BoardPanel.dock()
  core.add_thread(function()
    local ok, treeview = pcall(require, "plugins.treeview")
    if not ok or type(treeview) ~= "table" or not treeview.node then return end
    local node = core.root_view.root_node:get_node_for_view(treeview)
    if not node then return end
    BoardPanel.view = BoardPanel()
    node:split("down", BoardPanel.view, { y = true })
  end)
end


return BoardPanel
