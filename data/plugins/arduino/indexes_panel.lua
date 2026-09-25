-- Panel of the New Project page to see, add and remove board index URLs
-- (arduino-cli's board_manager.additional_urls).
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local cli = require "plugins.arduino.cli"
local project = require "plugins.arduino.project"
local ui = require "plugins.arduino.ui"

local IndexesPanel = {}
IndexesPanel.__index = IndexesPanel

function IndexesPanel.new(view)
  local panel = setmetatable({ view = view, input = "", urls = nil, failed = {}, busy = "Loading..." }, IndexesPanel)
  core.add_thread(function()
    panel.urls = project.additional_urls()
    panel.busy = nil
    core.redraw = true
  end)
  return panel
end


function IndexesPanel:set_status(text, is_error, details)
  self.status, self.status_is_error, self.status_details = text, is_error, details
  core.redraw = true
end


local function family_count(view)
  local n = 0
  for _, family in ipairs(view:get_families()) do
    if family.platform then n = n + 1 end
  end
  return n
end


function IndexesPanel:add()
  local url = self.input:gsub("^%s+", ""):gsub("%s+$", "")
  if self.busy or url == "" then return end
  if not url:match("^https?://") and not url:match("^file://") then
    self:set_status("A board index URL starts with https:// (or http://) and usually ends in _index.json.", true)
    return
  end
  for _, existing in ipairs(self.urls or {}) do
    if existing == url then
      self:set_status("This URL is already in the list.", true)
      return
    end
  end
  self.busy = "Adding the index and downloading it..."
  self:set_status(nil)
  core.add_thread(function()
    local before = family_count(self.view)
    local added, err = project.add_index_url(url)
    self.urls = project.additional_urls()
    self.busy = nil
    if not added then
      self:set_status("Could not add the URL.", true, err)
      return
    end
    self.input = ""
    if err then
      self.failed[url] = true
      local explanation = cli.explain_error(err)
      self:set_status("The URL was added, but its index could not be downloaded. "
        .. (explanation or "") .. " Check the URL, or remove it from the list.", true, err)
      return
    end
    self.failed[url] = nil
    project.forget_cache()
    self.view:load_data()
    local new = family_count(self.view) - before
    self:set_status("Added. " .. (new > 0 and (new .. " new board " .. (new == 1 and "family is" or "families are")
      .. " now listed.") or "No new board families were found in it."), false)
  end)
end


function IndexesPanel:remove(url)
  if self.busy then return end
  self.busy = "Removing..."
  core.add_thread(function()
    local ok, err = project.remove_index_url(url)
    self.urls = project.additional_urls()
    self.failed[url] = nil
    project.forget_cache()
    self.view:load_data()
    self.busy = nil
    if ok then
      self:set_status("Removed " .. url, false)
    else
      self:set_status("Could not remove the URL.", true, err)
    end
  end)
end


-------------------------------------------------------------------------------
-- Panel interface used by the New Project page
-------------------------------------------------------------------------------

function IndexesPanel:buttons()
  return {
    back = { text = "←  Back", run = function() self.view:close_panel() end },
    next = { text = "Add Index", run = function() self:add() end, enabled = not self.busy and self.input ~= "" },
    hint = "Paste a URL, then Enter",
  }
end

function IndexesPanel:enter() self:add() end

function IndexesPanel:escape()
  if self.input ~= "" then
    self.input = ""
    core.redraw = true
  else
    self.view:close_panel()
  end
end

function IndexesPanel:backspace()
  if self.input ~= "" then
    self.input = ui.remove_last_char(self.input)
    core.redraw = true
  else
    self.view:close_panel()
  end
end

function IndexesPanel:text_input(text)
  if self.busy then return end
  self.input = self.input .. text:gsub("[\r\n]", "")
  self.status = nil
  core.redraw = true
end

function IndexesPanel:wants_text() return true end


function IndexesPanel:layout(rect, add_target)
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local line_h = font:get_height() + pad_y / 2
  local row_h = font:get_height() + pad_y
  local L = { rows = {} }
  -- intro text height is measured the same way it is drawn
  local text_w = rect.w - pad_x * 2
  local y = rect.y + pad_y
  L.intro_y = y
  for _, text in ipairs(self:intro()) do
    y = y + #ui.wrap_text(font, text, text_w) * line_h + pad_y / 2
  end
  y = y + pad_y / 2
  local urls = { { url = project.DEFAULT_INDEX_URL, fixed = true } }
  for _, url in ipairs(self.urls or {}) do table.insert(urls, { url = url }) end
  local remove_w = font:get_width("Remove") + pad_x * 2
  for _, entry in ipairs(urls) do
    local row = { entry = entry, x = rect.x + pad_x, y = y, w = rect.w - pad_x * 2, h = row_h }
    if not entry.fixed then
      row.remove = { id = "index:remove:" .. entry.url, x = row.x + row.w - remove_w, y = y + 2, w = remove_w,
        h = row_h - 4, text = "Remove", enabled = not self.busy }
      add_target(row.remove.id, row.remove.x, row.remove.y, row.remove.w, row.remove.h, function() self:remove(entry.url) end)
    end
    table.insert(L.rows, row)
    y = y + row_h
  end
  y = y + pad_y
  L.box = { x = rect.x + pad_x, y = y, w = rect.w - pad_x * 2, h = font:get_height() + pad_y * 2 }
  L.status_y = L.box.y + L.box.h + pad_y
  self.current_layout = L
end


function IndexesPanel:intro()
  return {
    "A board index lists the board families you can install. Arduino's own index is always used.",
    "Other makers publish their own index for their boards (for example the Raspberry Pi Pico or STM32 cores). "
      .. "Paste its URL below to add their boards to the list.",
  }
end


function IndexesPanel:draw(rect, hovered_id)
  local L = self.current_layout
  if not L then return end
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, style.background2)
  core.push_clip_rect(rect.x, rect.y, rect.w, rect.h)
  local W = ui.writer(rect.x + pad_x, L.intro_y, rect.w - pad_x * 2)
  local intro = self:intro()
  W.paragraph(intro[1], style.text)
  W.paragraph(intro[2], style.dim)

  for _, row in ipairs(L.rows) do
    local entry = row.entry
    local label = entry.fixed and "Arduino (always used)" or (self.failed[entry.url] and "Could not download" or "Extra index")
    local color = entry.fixed and style.dim or (self.failed[entry.url] and style.error or style.text)
    local label_end = common.draw_text(font, color, label, "left", row.x, row.y, 0, row.h)
    local url_x = label_end + pad_x
    local url_w = (row.remove and row.remove.x or row.x + row.w) - pad_x - url_x
    common.draw_text(font, style.accent, ui.truncate(font, entry.url, url_w), "left", url_x, row.y, 0, row.h)
    if row.remove then ui.draw_button(row.remove, hovered_id == row.remove.id, false) end
  end
  if self.urls and #self.urls == 0 then
    common.draw_text(font, style.dim, "No extra indexes yet.", "left", rect.x + pad_x,
      L.rows[#L.rows].y + L.rows[#L.rows].h, 0, font:get_height() + pad_y)
  end

  ui.draw_text_box(L.box, self.input, "Paste the URL of a board index, e.g. https://.../package_example_index.json",
    not self.busy and core.active_view == self.view)

  local S = ui.writer(rect.x + pad_x, L.status_y, rect.w - pad_x * 2)
  if self.busy then
    S.paragraph(self.busy, style.dim)
  elseif self.status then
    S.paragraph(self.status, self.status_is_error and style.error or style.good)
    if self.status_details then S.paragraph("Details: " .. self.status_details, style.dim) end
  end
  core.pop_clip_rect()
end


return IndexesPanel
