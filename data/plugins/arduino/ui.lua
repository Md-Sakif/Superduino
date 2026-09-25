-- Drawing helpers shared by Superduino's pages.
local core = require "core"
local common = require "core.common"
local style = require "core.style"

local ui = {}

local heading_font, heading_scale
---Font for page titles.
function ui.heading_font()
  if heading_scale ~= SCALE then
    heading_font = style.font:copy(math.floor(26 * SCALE))
    heading_scale = SCALE
  end
  return heading_font
end


function ui.draw_border(x, y, w, h, color)
  local t = math.max(1, math.floor(SCALE))
  renderer.draw_rect(x, y, w, t, color)
  renderer.draw_rect(x, y + h - t, w, t, color)
  renderer.draw_rect(x, y, t, h, color)
  renderer.draw_rect(x + w - t, y, t, h, color)
end


---Draws a button { x, y, w, h, text, enabled }.
---@param hovered boolean
---@param primary boolean Primary buttons get an accent border.
function ui.draw_button(button, hovered, primary)
  if not button then return end
  local bg = (hovered and button.enabled) and style.selection or style.line_highlight
  renderer.draw_rect(button.x, button.y, button.w, button.h, bg)
  if primary and button.enabled then ui.draw_border(button.x, button.y, button.w, button.h, style.caret) end
  local color = not button.enabled and style.dim or (primary and style.accent or style.text)
  common.draw_text(style.font, color, button.text, "center", button.x, button.y, button.w, button.h)
end


---Removes the last UTF-8 character of `text`.
function ui.remove_last_char(text)
  return (text:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""))
end


---Cuts text to fit in `width` pixels, ending it with an ellipsis when shortened.
function ui.truncate(font, text, width)
  if font:get_width(text) <= width then return text end
  local ellipsis = "\u{2026}"
  local cut = text
  while cut ~= "" and font:get_width(cut .. ellipsis) > width do
    cut = ui.remove_last_char(cut)
  end
  return cut ~= "" and (cut:gsub("[%s,]+$", "") .. ellipsis) or ""
end


---Splits text into lines that fit in `width` pixels; keeps explicit line breaks.
function ui.wrap_text(font, text, width)
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if line ~= "" and font:get_width(candidate) > width then
        table.insert(lines, line)
        line = word
      else
        line = candidate
      end
    end
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end


---Writes wrapped paragraphs top to bottom inside a rectangle.
---@return table writer with `paragraph(text, color, font?)`, `gap()`, and fields x, y, w
function ui.writer(x, y, w)
  local writer = { x = x, y = y, w = w }
  function writer.paragraph(text, color, font)
    font = font or style.font
    local line_h = font:get_height() + style.padding.y / 2
    for _, line in ipairs(ui.wrap_text(font, text, w)) do
      common.draw_text(font, color, line, "left", writer.x, writer.y, 0, line_h)
      writer.y = writer.y + line_h
    end
    writer.y = writer.y + style.padding.y / 2
  end
  function writer.gap(h)
    writer.y = writer.y + (h or style.padding.y)
  end
  return writer
end


---Draws a single-line text box with a caret.
---@param box { x: number, y: number, w: number, h: number }
---@param value string
---@param placeholder string
---@param focused boolean
function ui.draw_text_box(box, value, placeholder, focused)
  local font = style.font
  renderer.draw_rect(box.x, box.y, box.w, box.h, style.background2)
  ui.draw_border(box.x, box.y, box.w, box.h, focused and style.caret or style.line_highlight)
  local text_x = box.x + style.padding.x
  core.push_clip_rect(box.x, box.y, box.w, box.h)
  local caret_x = text_x
  -- keep the end of long text (where typing happens) visible
  local shown = value
  local max_w = box.w - style.padding.x * 2
  if font:get_width(shown) > max_w then
    while shown ~= "" and font:get_width("\u{2026}" .. shown) > max_w do shown = shown:sub(2) end
    shown = "\u{2026}" .. shown
  end
  if value == "" then
    common.draw_text(font, style.dim, placeholder, "left", text_x, box.y, 0, box.h)
  else
    caret_x = common.draw_text(font, style.text, shown, "left", text_x, box.y, 0, box.h)
  end
  if focused then
    local caret_h = font:get_height()
    renderer.draw_rect(caret_x, box.y + (box.h - caret_h) / 2, math.max(1, math.floor(SCALE * 2)), caret_h, style.caret)
  end
  core.pop_clip_rect()
end


---Draws selectable list rows { item = { label, note?, detail?, detail_color? }, x, y, w, h, index, id }.
---@param rows table[]
---@param selected integer
---@param hovered_id string?
function ui.draw_rows(rows, selected, hovered_id)
  local font = style.font
  local pad_x = style.padding.x
  for _, row in ipairs(rows) do
    local is_selected = row.index == selected
    if is_selected then
      renderer.draw_rect(row.x, row.y, row.w, row.h, style.selection)
      renderer.draw_rect(row.x, row.y, math.max(1, math.floor(SCALE * 3)), row.h, style.caret)
    elseif hovered_id == row.id then
      renderer.draw_rect(row.x, row.y, row.w, row.h, style.line_highlight)
    end
    local item = row.item
    -- dim text is hard to read on the selection color
    local secondary = is_selected and style.text or style.dim
    core.push_clip_rect(row.x, row.y, row.w - pad_x, row.h)
    local label_end = common.draw_text(font, item.color or style.accent, item.label, "left", row.x + pad_x, row.y, 0, row.h)
    local detail_x = row.x + row.w - pad_x
    if item.detail then
      detail_x = detail_x - font:get_width(item.detail)
      common.draw_text(font, item.detail_color or secondary, item.detail, "left", detail_x, row.y, 0, row.h)
    end
    if item.note then
      local note_x = label_end + pad_x
      common.draw_text(font, secondary, ui.truncate(font, item.note, detail_x - pad_x - note_x), "left", note_x, row.y, 0, row.h)
    end
    core.pop_clip_rect()
  end
end


---"3 days ago", "2 hours ago", "just now".
---@param seconds number
function ui.age(seconds)
  if seconds < 90 then return "just now" end
  local units = { { 86400, "day" }, { 3600, "hour" }, { 60, "minute" } }
  for _, unit in ipairs(units) do
    local n = math.floor(seconds / unit[1])
    if n >= 1 then return n .. " " .. unit[2] .. (n == 1 and "" or "s") .. " ago" end
  end
  return "just now"
end


return ui
