-- The panel bar under the editor area, right of the left pane and above the
-- status bar: tabs that show or hide panels. For now one tab, Output, which
-- shows or hides the Output panel above the bar.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local OutputView = require "plugins.arduino.output_view"

---@class arduino.panelbar : core.view
local PanelBar = View:extend()

function PanelBar:__tostring() return "PanelBar" end

PanelBar.save_in_workspace = false


local function output_visible()
  return OutputView.view ~= nil and OutputView.view.visible
end

PanelBar.TABS = {
  {
    id = "tab:output",
    text = "Output",
    active = output_visible,
    run = function()
      if output_visible() then OutputView.view:hide() else OutputView.get():show() end
    end,
  },
}


function PanelBar:new()
  PanelBar.super.new(self)
  self.hovered_id = nil
  self.tabs = {}
end


function PanelBar:height()
  -- as tall as the status bar
  return style.font:get_height() + style.padding.y * 2
end


function PanelBar:update()
  self.size.y = self:height()
  PanelBar.super.update(self)
  -- tabs from the left
  local font, pad_x = style.font, style.padding.x
  local x = self.position.x
  self.tabs = {}
  for _, tab in ipairs(PanelBar.TABS) do
    local w = font:get_width(tab.text) + pad_x * 2
    table.insert(self.tabs, { tab = tab, x = x, y = self.position.y, w = w, h = self.size.y })
    x = x + w
  end
end


function PanelBar:tab_at(x, y)
  for _, t in ipairs(self.tabs) do
    if x >= t.x and x < t.x + t.w and y >= t.y and y < t.y + t.h then return t end
  end
end


function PanelBar:on_mouse_moved(x, y, ...)
  PanelBar.super.on_mouse_moved(self, x, y, ...)
  local t = self:tab_at(x, y)
  local id = t and t.tab.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = t and "hand" or "arrow"
end


function PanelBar:on_mouse_left()
  PanelBar.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function PanelBar:on_mouse_pressed(button, x, y)
  local t = button == "left" and self:tab_at(x, y)
  if t then t.tab.run() end
  return true
end


function PanelBar:draw()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  renderer.draw_rect(x, y, w, h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  for _, t in ipairs(self.tabs) do
    local active = t.tab.active()
    local hovered = self.hovered_id == t.tab.id
    if hovered or active then renderer.draw_rect(t.x, t.y, t.w, t.h, style.line_highlight) end
    if active then
      -- like the active tab of the editor: a line on its edge
      local line = math.max(1, math.floor(SCALE * 2))
      renderer.draw_rect(t.x, t.y, t.w, line, style.caret)
    end
    local color = hovered and style.accent or (active and style.text or style.dim)
    common.draw_text(style.font, color, t.tab.text, "center", t.x, t.y, t.w, t.h)
  end
end


---Adds the bar under the editor area, once the left pane exists (so the bar
---starts right of it).
function PanelBar.dock()
  core.add_thread(function()
    local node = core.root_view:get_primary_node()
    local last_active = core.active_view
    PanelBar.view = PanelBar()
    node:split("down", PanelBar.view, { y = true })
    if last_active then core.set_active_view(last_active) end
  end)
end


command.add(nil, {
  ["arduino:toggle-output"] = function() PanelBar.TABS[1].run() end,
})


return PanelBar
