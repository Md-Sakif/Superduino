-- The Terminal panel: the bundled terminal plugin's drawer (a shell in the
-- project folder), with a header like the Output panel's: its title and Hide.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local ui = require "plugins.arduino.ui"
local bottom_panels = require "plugins.arduino.bottom_panels"

local terminal_panel = {}

-- the plugin, when it could be loaded (its native part may be missing)
local ok, plugin = pcall(require, "plugins.terminal")
terminal_panel.available = ok and type(plugin) == "table" and plugin.class ~= nil
if not terminal_panel.available then
  core.log_quiet("Terminal not available: %s", tostring(plugin))
  return terminal_panel
end
local TerminalView = plugin.class


local function header_height()
  -- as tall as the Output panel's header
  return style.font:get_height() + style.padding.y * 2
end

-- the same margins as the Output panel (the plugin draws from the very edge),
-- with room for the header above the lines
config.plugins.terminal.padding = { x = style.padding.x, y = math.floor(style.padding.y / 2), top = header_height() }


---Whether the terminal drawer is open.
function terminal_panel.is_open()
  return core.terminal_view ~= nil and core.terminal_view_node ~= nil and core.terminal_view_closed == nil
end


---Opens the drawer (made the first time) and gives the shell the keyboard.
function terminal_panel.open()
  bottom_panels.showing("terminal")
  if not terminal_panel.is_open() then command.perform("terminal:toggle-drawer") end
end


---Hides the drawer; the shell keeps running.
function terminal_panel.close()
  if terminal_panel.is_open() then command.perform("terminal:toggle-drawer") end
end


bottom_panels.add({ id = "terminal", is_open = terminal_panel.is_open, close = terminal_panel.close })


-- Header links of a terminal view (only the drawer can be hidden), in screen coordinates.
local function header_links(view)
  local links = {}
  if view ~= core.terminal_view then return links end
  local font, pad_x = style.font, style.padding.x
  local w = font:get_width("Hide") + pad_x
  table.insert(links, { id = "terminal:hide", text = "Hide", x = view.position.x + view.size.x - pad_x - w,
    y = view.position.y, w = w, h = header_height(), run = terminal_panel.close })
  return links
end


local function link_at(view, x, y)
  for _, link in ipairs(header_links(view)) do
    if x >= link.x and x < link.x + link.w and y >= link.y and y < link.y + link.h then return link end
  end
end


local update = TerminalView.update
function TerminalView:update(...)
  -- follows scale changes
  self.options.padding.top = header_height()
  return update(self, ...)
end


local draw = TerminalView.draw
function TerminalView:draw(...)
  draw(self, ...)
  local x, y, w, h = self.position.x, self.position.y, self.size.x, header_height()
  if self.size.y < h then return end
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  local pad_x = style.padding.x
  local links = header_links(self)
  local right = links[1] and links[1].x or (x + w)
  -- the program running in the shell, else the shell (as the plugin's status item does)
  local name = self.terminal and self.terminal:name() or common.basename(self.options.shell or "shell")
  local dir = self.options.environment and self.options.environment.PWD
  local title = "Terminal: " .. name .. (type(dir) == "string" and (" in " .. common.basename(dir)) or "")
  common.draw_text(style.font, style.text, ui.truncate(style.font, title, right - x - pad_x * 2), "left", x + pad_x, y, 0, h)
  for _, link in ipairs(links) do
    common.draw_text(style.font, self.hovered_header_link == link.id and style.accent or style.text, link.text,
      "center", link.x, link.y, link.w, link.h)
  end
end


local on_mouse_moved = TerminalView.on_mouse_moved
function TerminalView:on_mouse_moved(x, y, ...)
  local link = link_at(self, x, y)
  local id = link and link.id
  if id ~= self.hovered_header_link then
    self.hovered_header_link = id
    core.redraw = true
  end
  if y < self.position.y + header_height() then
    self.cursor = link and "hand" or "arrow"
    return true
  end
  self.cursor = "ibeam"
  return on_mouse_moved(self, x, y, ...)
end


local on_mouse_pressed = TerminalView.on_mouse_pressed
function TerminalView:on_mouse_pressed(button, x, y, ...)
  if y < self.position.y + header_height() then
    local link = button == "left" and link_at(self, x, y)
    if link then link.run() end
    return true
  end
  return on_mouse_pressed(self, button, x, y, ...)
end


return terminal_panel
