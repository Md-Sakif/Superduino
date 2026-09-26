-- The Output panel under the editor: the output of the latest build or upload.
-- Compiler messages open their file at the line when clicked.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local build = require "plugins.arduino.build"
local ui = require "plugins.arduino.ui"

---@class arduino.outputview : core.view
local OutputView = View:extend()

function OutputView:__tostring() return "OutputView" end

OutputView.save_in_workspace = false

OutputView.DEFAULT_HEIGHT = 220


function OutputView:new()
  OutputView.super.new(self)
  self.scrollable = true
  self.visible = false
  self.target_height = OutputView.DEFAULT_HEIGHT * SCALE
  self.hovered_id = nil
  self.targets = {}
  self.shown_lines = 0
end


function OutputView:get_name() return "Output" end


-- Called while the divider above the panel is dragged.
function OutputView:set_target_size(axis, value)
  if axis ~= "y" then return false end
  self.target_height = math.max(value, self:header_height() * 2)
  return true
end


function OutputView:header_height()
  return style.font:get_height() + style.padding.y * 2
end


function OutputView:line_height()
  return style.code_font:get_height() + math.floor(style.padding.y / 3)
end


function OutputView:get_scrollable_size()
  local run = build.last
  return self:header_height() + (run and #run.lines or 0) * self:line_height() + style.padding.y * 2
end


function OutputView:show()
  if not self.visible then
    self.visible = true
    self.scroll.to.y = math.huge
    core.redraw = true
  end
end


function OutputView:hide()
  self.visible = false
  core.redraw = true
end


function OutputView:copy()
  local run = build.last
  if not run then return end
  local lines = {}
  for _, line in ipairs(run.lines) do table.insert(lines, line.text) end
  system.set_clipboard(table.concat(lines, "\n") .. "\n")
  core.log("Copied the output (%d lines)", #lines)
end


function OutputView:update()
  local dest = self.visible and self.target_height or 0
  self:move_towards(self.size, "y", dest, nil, "output")
  local run = build.last
  local count = run and #run.lines or 0
  if count ~= self.shown_lines then
    -- keep the end in view while output arrives, unless scrolled up to read
    local line_h = self:line_height()
    local old_end = self:header_height() + self.shown_lines * line_h + style.padding.y * 2 - self.size.y
    if count < self.shown_lines or self.scroll.to.y >= old_end - line_h then self.scroll.to.y = math.huge end
    self.shown_lines = count
  end
  OutputView.super.update(self)
  self:layout()
end


-- Clickable areas of the header and lines (in screen coordinates).
function OutputView:layout()
  self.targets = {}
  local run = build.last
  local font, pad_x = style.font, style.padding.x
  local x, y, w = self.position.x, self.position.y, self.size.x
  local header_h = self:header_height()
  -- header links, right to left
  local right = x + w - pad_x
  self.links = {}
  for _, link in ipairs({
    { id = "output:hide", text = "Hide", run = function() self:hide() end },
    { id = "output:copy", text = "Copy", run = function() self:copy() end, enabled = run ~= nil },
  }) do
    local lw = font:get_width(link.text) + pad_x
    link.x, link.y, link.w, link.h = right - lw, y, lw, header_h
    right = right - lw
    if link.enabled ~= false then table.insert(self.targets, link) end
    table.insert(self.links, link)
  end
  self.title_w = right - x - pad_x * 2
  -- clickable lines
  if run then
    local ox, oy = self:get_content_offset()
    local line_h = self:line_height()
    local first = math.max(1, math.floor((self.scroll.y - header_h) / line_h))
    for i = first, math.min(#run.lines, first + math.ceil(self.size.y / line_h) + 1) do
      local line = run.lines[i]
      if line.file or line.command then
        local ly = oy + header_h + (i - 1) * line_h
        table.insert(self.targets, { id = "line:" .. i, x = x, y = ly, w = w, h = line_h, line = line,
          run = function() self:open_line(line) end })
      end
    end
  end
end


---Opens the file of a compiler message at its line, or runs a hint's command.
---@param line arduino.build_line
function OutputView:open_line(line)
  if line.command then
    command.perform(line.command)
    return
  end
  if not line.file or not system.get_file_info(line.file) then
    core.warn("File not found: %s", tostring(line.file))
    return
  end
  local dv = core.root_view:open_doc(core.open_doc(line.file))
  dv.doc:set_selection(line.line or 1, line.col or 1)
  dv:scroll_to_line(line.line or 1, true, true)
end


function OutputView:target_at(x, y)
  -- the header is always on top of the lines
  local header = y < self.position.y + self:header_height()
  for _, target in ipairs(self.targets) do
    if (target.id:find("^output:") ~= nil) == header
      and x >= target.x and x < target.x + target.w and y >= target.y and y < target.y + target.h then
      return target
    end
  end
end


function OutputView:on_mouse_moved(x, y, ...)
  OutputView.super.on_mouse_moved(self, x, y, ...)
  local target = self:target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    core.redraw = true
  end
  self.cursor = target and "hand" or "arrow"
end


function OutputView:on_mouse_left()
  OutputView.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function OutputView:on_mouse_pressed(button, x, y, clicks)
  if OutputView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local target = button == "left" and self:target_at(x, y)
  if target then target.run() end
  return true
end


local LINE_COLORS = {
  command = "dim", error = "error", warning = "warn", note = "dim", summary = "good",
  hint = "accent", done = "good", failed = "error", text = "text",
}


---Title of the header, e.g. "Output: Uploading Blink to /dev/ttyUSB0".
function OutputView:title()
  local run = build.last
  if not run then return "Output", style.dim end
  local what = run.kind == "upload" and ("Upload of " .. common.basename(run.dir) .. " to " .. tostring(run.port))
    or ("Build of " .. common.basename(run.dir))
  local states = {
    running = { run.kind == "upload" and "uploading..." or "building...", style.accent },
    done = { "done", style.good },
    failed = { run.errors > 0 and string.format("failed: %d error%s", run.errors, run.errors == 1 and "" or "s")
      or "failed", style.error },
    cancelled = { "cancelled", style.warn },
  }
  local state = states[run.state] or { run.state, style.dim }
  return "Output: " .. what .. " - " .. state[1], state[2]
end


function OutputView:draw()
  if self.size.y < 1 then return end
  self:draw_background(style.background)
  local run = build.last
  local x, y, w = self.position.x, self.position.y, self.size.x
  local pad_x = style.padding.x
  local header_h = self:header_height()

  if run then
    local ox, oy = self:get_content_offset()
    local line_h = self:line_height()
    local first = math.max(1, math.floor((self.scroll.y - header_h) / line_h))
    core.push_clip_rect(x, y + header_h, w, self.size.y - header_h)
    for i = first, math.min(#run.lines, first + math.ceil(self.size.y / line_h) + 1) do
      local line = run.lines[i]
      local ly = oy + header_h + (i - 1) * line_h
      if self.hovered_id == "line:" .. i then renderer.draw_rect(x, ly, w, line_h, style.line_highlight) end
      local color = style[LINE_COLORS[line.kind] or "text"] or style.text
      common.draw_text(style.code_font, color, line.text, "left", x + pad_x, ly, 0, line_h)
    end
    core.pop_clip_rect()
  end

  -- header over the lines
  renderer.draw_rect(x, y, w, header_h, style.background2)
  renderer.draw_rect(x, y, w, math.max(1, SCALE), style.divider)
  local title, color = self:title()
  common.draw_text(style.font, color, ui.truncate(style.font, title, self.title_w or w), "left", x + pad_x, y, 0, header_h)
  for _, link in ipairs(self.links or {}) do
    local hovered = self.hovered_id == link.id
    common.draw_text(style.font, link.enabled == false and style.dim or (hovered and style.accent or style.text),
      link.text, "center", link.x, link.y, link.w, link.h)
  end
  self:draw_scrollbar()
end


---The panel, added under the editor the first time it is needed.
---@return arduino.outputview
function OutputView.get()
  if not OutputView.view then
    OutputView.view = OutputView()
    local node = core.root_view:get_primary_node()
    node:split("down", OutputView.view, { y = true }, true)
  end
  return OutputView.view
end


-- show the panel when a build starts, keep it when it fails
table.insert(build.on_start, function() OutputView.get():show() end)
table.insert(build.on_finish, function(run)
  if run.state == "failed" then OutputView.get():show() end
end)


return OutputView
