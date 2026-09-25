-- Step-by-step "New Project" page: vendor, architecture, board, then a name.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local EmptyView = require "core.emptyview"
local project = require "plugins.arduino.project"

---@class arduino.newprojectview : core.view
---@field super core.view
local NewProjectView = View:extend()

function NewProjectView:__tostring() return "NewProjectView" end

local STEPS = {
  {
    title = "Vendor",
    question = "Who makes your board?",
    hint = "Check the board or its box for the maker's name. Not sure? Choose Arduino.",
  },
  {
    title = "Architecture",
    question = "Which family does your board belong to?",
    hint = "A family is a group of boards built around the same kind of chip.",
  },
  {
    title = "Board",
    question = "Which board do you have?",
    hint = "Type to search, for example uno or nano.",
  },
  {
    title = "Name",
    question = "Give your project a name",
    hint = "Use letters, numbers, _ - or . (no spaces). For example: Blink",
  },
}
local NAME_STEP = #STEPS

local LIST_PLACEHOLDER = "Type to search..."
local NAME_PLACEHOLDER = "MyProject"
local KEYS_HINT = "Enter: continue    Backspace or Esc: go back"


---@type arduino.newprojectview?
local open_view


function NewProjectView:new()
  NewProjectView.super.new(self)
  self.step = 1
  self.choice = {} -- selected key for each list step
  self.filter = ""
  self.selected = 1
  self.first_row = 1
  self.name = ""
  self.location = nil
  self.boards = nil
  self.platforms = {}
  -- platform installation offered or in progress:
  -- { platform, state = "confirm"|"running"|"failed", handle, progress, done = {}, error }
  self.install = nil
  self.loading = true
  self.message = nil
  self.message_is_error = false
  self.creating = false
  self.hovered_id = nil
  self.targets = {}
  self:load()
end


function NewProjectView:get_name()
  return "New Project"
end


function NewProjectView:supports_text_input()
  return not self.creating and not self.install
end


function NewProjectView:try_close(do_close)
  if self.install and self.install.state == "running" then
    self.install.handle.cancelled = true
    core.log("Cancelled installing %s", self.install.platform.name)
  end
  if open_view == self then open_view = nil end
  NewProjectView.super.try_close(self, do_close)
end


-- Loads installed boards and all known platforms. Must be called from a thread.
function NewProjectView:load_data()
  local boards, err = project.load_boards()
  local platforms, platforms_err = project.load_platforms()
  if not platforms then
    -- still usable with the installed boards, e.g. when offline without an index
    core.warn("Could not load the list of installable boards: %s", tostring(platforms_err))
  end
  if not boards and not platforms then
    return false, "Could not load the list of boards: " .. tostring(err)
  end
  self.boards, self.platforms = boards or {}, platforms or {}
  self.list_key = nil
  return true
end


function NewProjectView:load()
  self.loading = true
  core.add_thread(function()
    local ok, err = self:load_data()
    self.location = project.sketchbook_dir()
    self.loading = false
    if not ok then
      self:set_message(err, true)
    else
      self:enter_step(1)
    end
    core.redraw = true
  end)
end


function NewProjectView:set_message(text, is_error)
  self.message, self.message_is_error = text, is_error
  core.redraw = true
end


-------------------------------------------------------------------------------
-- Choices
-------------------------------------------------------------------------------

-- "Arduino UNO, Arduino Nano and 25 more"
local function examples(names)
  if #names == 0 then return nil end
  local shown = {}
  for i = 1, math.min(3, #names) do shown[i] = names[i] end
  local text = table.concat(shown, ", ")
  if #names > 3 then text = text .. " and " .. (#names - 3) .. " more" end
  return text
end


local function count_boards(n)
  return n == 1 and "1 board" or (n .. " boards")
end


-- Families (platforms) of a vendor, installed or not, keyed by platform id:
-- { id, name, vendor, vendor_name, installed_version?, board_names, platform? }
function NewProjectView:get_families()
  local families, order = {}, {}
  for _, board in ipairs(self.boards or {}) do
    local family = families[board.arch]
    if not family then
      family = { id = board.arch, name = board.arch_name, vendor = board.vendor, vendor_name = board.vendor_name,
        installed_version = board.version, board_names = {} }
      families[board.arch] = family
      table.insert(order, family)
    end
    table.insert(family.board_names, board.name)
  end
  for _, platform in ipairs(self.platforms or {}) do
    local family = families[platform.id]
    if family then
      family.platform = platform
    elseif not platform.deprecated then
      family = { id = platform.id, name = platform.name, vendor = platform.vendor, vendor_name = platform.vendor_name,
        installed_version = platform.installed_version, board_names = platform.board_names, platform = platform }
      families[platform.id] = family
      table.insert(order, family)
    end
  end
  return order
end


-- Items of a list step as { key, label, note?, detail?, installed? }.
function NewProjectView:get_step_items(step)
  local items, seen = {}, {}
  if step == 1 then
    for _, family in ipairs(self:get_families()) do
      local item = seen[family.vendor]
      if not item then
        item = { key = family.vendor, label = family.vendor_name, count = 0, installed = false }
        seen[family.vendor] = item
        table.insert(items, item)
      end
      item.count = item.count + #family.board_names
      item.installed = item.installed or family.installed_version ~= nil
    end
    for _, item in ipairs(items) do
      item.note = count_boards(item.count)
      item.detail = item.installed and "installed" or "not installed"
    end
    table.sort(items, function(a, b)
      -- Arduino first, since it is what most people start with, then installed ones
      if (a.key == "arduino") ~= (b.key == "arduino") then return a.key == "arduino" end
      if a.installed ~= b.installed then return a.installed end
      return a.label:lower() < b.label:lower()
    end)
  elseif step == 2 then
    for _, family in ipairs(self:get_families()) do
      if family.vendor == self.choice[1] then
        table.insert(items, {
          key = family.id,
          label = family.name,
          note = examples(family.board_names),
          detail = family.installed_version and ("installed " .. family.installed_version) or "not installed",
          installed = family.installed_version ~= nil,
          family = family,
        })
      end
    end
    table.sort(items, function(a, b)
      if a.installed ~= b.installed then return a.installed end
      return a.label:lower() < b.label:lower()
    end)
  elseif step == 3 then
    for _, board in ipairs(self.boards or {}) do
      if board.arch == self.choice[2] then
        table.insert(items, { key = board.fqbn, label = board.name, detail = board.fqbn, board = board, installed = true })
      end
    end
  end
  return items
end


-- Orders items for the typed text: exact id or name first, then names with a
-- word starting with the text, then any that contain it, then fuzzy matches.
-- Plain fuzzy matching alone would rank e.g. "Arduino BT" above "Arduino UNO"
-- for "uno", because the letters u-n-o also appear in "arduino".
local function filter_items(items, text)
  local needle = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if needle == "" then return items end
  local word_start = "%f[%w]" .. needle:gsub("%p", "%%%0")
  local groups = { {}, {}, {} }
  local fuzzy = {}
  for _, item in ipairs(items) do
    local label, detail = item.label:lower(), (item.detail or ""):lower()
    local id = item.key:lower():match("[^:]+$")
    if id == needle or label == needle or item.key:lower() == needle then
      table.insert(groups[1], item)
    elseif id:sub(1, #needle) == needle or label:find(word_start) then
      table.insert(groups[2], item)
    elseif label:find(needle, 1, true) or detail:find(needle, 1, true) then
      table.insert(groups[3], item)
    else
      local score = system.fuzzy_match(item.label .. " " .. (item.detail or ""), text, false)
      if score then table.insert(fuzzy, { item = item, score = score }) end
    end
  end
  table.sort(fuzzy, function(a, b) return a.score > b.score end)
  local result = {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group) do table.insert(result, item) end
  end
  -- fuzzy matches are mostly noise next to real matches, so only use them as a fallback
  if #result == 0 then
    for _, entry in ipairs(fuzzy) do table.insert(result, entry.item) end
  end
  return result
end


-- Visible items of the current list step, filtered by the search text.
function NewProjectView:get_list()
  local key = self.step .. "\0" .. tostring(self.choice[1]) .. "\0" .. tostring(self.choice[2]) .. "\0" .. self.filter
  if self.list_key ~= key or self.list_boards ~= self.boards or self.list_platforms ~= self.platforms then
    self.list_key, self.list_boards, self.list_platforms = key, self.boards, self.platforms
    self.list = filter_items(self:get_step_items(self.step), self.filter)
  end
  return self.list
end


function NewProjectView:get_board()
  for _, item in ipairs(self:get_step_items(3)) do
    if item.key == self.choice[3] then return item.board end
  end
end


-- Short text describing what was chosen at a list step.
function NewProjectView:choice_label(step)
  for _, item in ipairs(self:get_step_items(step)) do
    if item.key == self.choice[step] then return item.label end
  end
end


-------------------------------------------------------------------------------
-- Navigation
-------------------------------------------------------------------------------

function NewProjectView:enter_step(step)
  self.step = step
  self.filter = ""
  self.selected, self.first_row = 1, 1
  if step < NAME_STEP then
    for i, item in ipairs(self:get_list()) do
      if item.key == self.choice[step] then self.selected = i break end
    end
  end
  if not self.message_is_error then self.message = nil end
  core.redraw = true
end


function NewProjectView:can_go_to(step)
  if not self.boards or self.creating or self.install then return false end
  for i = 1, step - 1 do
    if not self.choice[i] then return false end
  end
  return true
end


function NewProjectView:next()
  if self.creating or not self.boards then return end
  if self.step == NAME_STEP then
    self:create()
    return
  end
  if self.install then
    if self.install.state ~= "running" then self:start_install() end
    return
  end
  local item = self:get_list()[self.selected]
  if not item then return end
  if self.step == 2 and not item.installed then
    self.install = { platform = item.family, state = "confirm" }
    self.message = nil
    core.redraw = true
    return
  end
  if self.choice[self.step] ~= item.key then
    self.choice[self.step] = item.key
    -- later choices depended on this one
    for i = self.step + 1, NAME_STEP - 1 do self.choice[i] = nil end
  end
  self.message = nil
  self:enter_step(self.step + 1)
end


function NewProjectView:back()
  if self.install then
    if self.install.state ~= "running" then self.install = nil end
    core.redraw = true
    return
  end
  if self.creating or self.step == 1 then return end
  self.message = nil
  self:enter_step(self.step - 1)
end


function NewProjectView:move_selection(delta)
  if self.step == NAME_STEP or self.install then return end
  local count = #self:get_list()
  if count == 0 then return end
  self.selected = common.clamp(self.selected + delta, 1, count)
  self:scroll_to_selected()
  core.redraw = true
end


function NewProjectView:scroll_to_selected()
  local rows = self.visible_rows or 1
  if self.selected < self.first_row then
    self.first_row = self.selected
  elseif self.selected >= self.first_row + rows then
    self.first_row = self.selected - rows + 1
  end
end


function NewProjectView:type_text(text)
  if self.creating or self.install then return end
  text = text:gsub("[\r\n]", "")
  if self.step == NAME_STEP then
    self.name = self.name .. text
    self.message = nil
  else
    self.filter = self.filter .. text
    self.selected, self.first_row = 1, 1
  end
  core.redraw = true
end


local function remove_last_char(text)
  return (text:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""))
end


function NewProjectView:backspace()
  if self.creating then return end
  if self.install then
    self:back()
    return
  end
  if self.step == NAME_STEP and self.name ~= "" then
    self.name = remove_last_char(self.name)
    self.message = nil
  elseif self.step < NAME_STEP and self.filter ~= "" then
    self.filter = remove_last_char(self.filter)
    self.selected, self.first_row = 1, 1
  else
    self:back()
  end
  core.redraw = true
end


function NewProjectView:escape()
  if self.step < NAME_STEP and self.filter ~= "" and not self.install then
    self.filter = ""
    self.selected, self.first_row = 1, 1
    core.redraw = true
  else
    self:back()
  end
end


function NewProjectView:project_path()
  return self.location and (self.location .. PATHSEP .. self.name)
end


function NewProjectView:name_problem()
  local problem = project.name_problem(self.name)
  if problem then return problem end
  local path = self:project_path()
  if path and system.get_file_info(path) then
    return common.home_encode(path) .. " already exists; choose another name"
  end
end


function NewProjectView:change_location()
  local function use(dir)
    local info = dir and system.get_file_info(dir)
    if not info or info.type ~= "dir" then
      self:set_message("Not a folder: " .. tostring(dir), true)
      return
    end
    self.location = dir
    self.message = nil
    core.redraw = true
  end
  if config.use_system_file_picker then
    core.open_directory_dialog(core.window, function(status, result)
      if status == "accept" then use(result[1]) end
    end, { default_location = self.location, title = "Where to create the project" })
    return
  end
  core.command_view:enter("Create Project In", {
    text = self.location and (common.home_encode(self.location) .. PATHSEP) or "",
    submit = function(text)
      use(system.absolute_path(common.home_expand(text)))
    end,
    suggest = function(text)
      return common.home_encode_list(common.dir_path_suggest(common.home_expand(text), self.location or HOME))
    end,
  })
end


function NewProjectView:start_install()
  local install = self.install
  install.state, install.error = "running", nil
  self.message = nil
  install.handle, install.progress, install.done, install.current = {}, nil, {}, "Starting..."
  core.redraw = true
  core.add_thread(function()
    local ok, err = project.install_platform(install.platform.id, install.handle, function(event)
      if event.kind == "progress" then
        install.progress = event
        install.current = "Downloading " .. event.item
      elseif event.kind == "downloaded" then
        install.progress = nil
        table.insert(install.done, "Downloaded " .. event.item)
      elseif event.kind == "installing" then
        install.progress = nil
        install.current = "Installing " .. event.item
      elseif event.kind == "installed" then
        table.insert(install.done, "Installed " .. event.item)
      end
      core.redraw = true
    end)
    if self.install ~= install then return end
    if err == "cancelled" then
      self.install = nil
      self:set_message("Installation of " .. install.platform.name .. " was cancelled.", false)
      return
    end
    if not ok then
      install.state, install.error = "failed", err
      core.redraw = true
      return
    end
    install.current = "Loading the new boards..."
    core.redraw = true
    project.forget_cache()
    local loaded, load_err = self:load_data()
    self.install = nil
    if not loaded then
      self:set_message(load_err, true)
      return
    end
    core.log("Installed %s", install.platform.name)
    self.choice[2], self.choice[3] = install.platform.id, nil
    self:enter_step(3)
    self:set_message("Installed " .. install.platform.name .. ". Now choose your board.", false)
  end)
end


function NewProjectView:cancel_install()
  if self.install and self.install.state == "running" then
    self.install.handle.cancelled = true
    self.install.current = "Cancelling..."
    core.redraw = true
  end
end


function NewProjectView:create()
  local problem = self:name_problem()
  if problem then
    self:set_message(problem, true)
    return
  end
  local board, path = self:get_board(), self:project_path()
  if not board or not path then return end
  self.creating = true
  self:set_message("Creating " .. self.name .. "...", false)
  core.add_thread(function()
    local ok, err = project.create(path, board)
    self.creating = false
    if not ok then
      self:set_message("Could not create the project: " .. tostring(err), true)
      return
    end
    self:set_message("Created " .. self.name .. ". Opening it...", false)
    project.open(path)
  end)
end


-------------------------------------------------------------------------------
-- Layout and drawing
-------------------------------------------------------------------------------

local heading_font, heading_scale
local function get_heading_font()
  if heading_scale ~= SCALE then
    heading_font = style.font:copy(math.floor(26 * SCALE))
    heading_scale = SCALE
  end
  return heading_font
end


-- Adds a clickable area; hit-testing uses the areas of the latest layout.
function NewProjectView:add_target(id, x, y, w, h, run)
  table.insert(self.targets, { id = id, x = x, y = y, w = w, h = h, run = run })
end


function NewProjectView:update()
  NewProjectView.super.update(self)
  self:layout()
end


function NewProjectView:layout()
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local line_h = font:get_height()
  local row_h = line_h + pad_y
  local box_h = line_h + pad_y * 2
  local L = {}
  self.targets = {}

  L.w = math.min(self.size.x - pad_x * 4, math.floor(720 * SCALE))
  L.x = self.position.x + math.floor((self.size.x - L.w) / 2)
  local y = self.position.y + pad_y * 3

  L.title_y = y
  y = y + get_heading_font():get_height() + pad_y

  -- step bar: completed steps show the choice and can be clicked to go back
  L.crumbs = {}
  local x = L.x
  for i, step in ipairs(STEPS) do
    local text = (i < self.step and i < NAME_STEP and self:choice_label(i)) or step.title
    local w = font:get_width(text)
    local crumb = { text = text, x = x, y = y, w = w, h = row_h, index = i }
    table.insert(L.crumbs, crumb)
    if i ~= self.step and self:can_go_to(i) and (i < self.step or self.choice[i - 1]) then
      crumb.id = "crumb:" .. i
      self:add_target(crumb.id, x - pad_x / 2, y, w + pad_x, row_h, function() self:enter_step(i) end)
    end
    x = x + w + font:get_width("  ›  ")
  end
  y = y + row_h + pad_y * 2

  L.question_y = y
  y = y + line_h + pad_y / 2
  L.hint_y = y
  y = y + line_h + pad_y * 1.5

  L.box = { x = L.x, y = y, w = L.w, h = box_h }
  y = y + box_h + pad_y

  -- bottom: message line, then buttons
  local button_h = box_h
  L.buttons_y = self.position.y + self.size.y - pad_y * 3 - button_h
  L.message_y = L.buttons_y - pad_y - row_h

  local next_text, next_run, next_enabled = "Next  →", function() self:next() end, true
  local back_text, back_run = self.step > 1 and "←  Back" or nil, function() self:back() end
  L.next_primary = true
  if self.install then
    local state = self.install.state
    if state == "confirm" then
      next_text, back_text = "Download and Install", "Not Now"
    elseif state == "running" then
      next_text, next_run, back_text = "Cancel", function() self:cancel_install() end, nil
      next_enabled = not self.install.handle.cancelled
      L.next_primary = false
    else
      next_text, back_text = "Try Again", "←  Back"
    end
  elseif self.step == NAME_STEP then
    next_text = "Create Project"
  else
    next_enabled = self:get_list()[self.selected] ~= nil
  end
  next_enabled = next_enabled and not self.creating and self.boards ~= nil

  local next_w = font:get_width(next_text) + pad_x * 3
  L.next = { id = "button:next", text = next_text, x = L.x + L.w - next_w, y = L.buttons_y, w = next_w, h = button_h,
    enabled = next_enabled }
  if L.next.enabled then
    self:add_target(L.next.id, L.next.x, L.next.y, L.next.w, L.next.h, next_run)
  end
  if back_text then
    local back_w = font:get_width(back_text) + pad_x * 3
    L.back = { id = "button:back", text = back_text, x = L.x, y = L.buttons_y, w = back_w, h = button_h,
      enabled = not self.creating }
    if L.back.enabled then
      self:add_target(L.back.id, L.back.x, L.back.y, L.back.w, L.back.h, back_run)
    end
  end

  if self.step == NAME_STEP then
    L.problem_y = y - pad_y / 2
    y = y + row_h + pad_y / 2
    L.location_y = y
    local change_text = "Change Folder..."
    local change_w = font:get_width(change_text) + pad_x * 2
    L.change = { id = "button:location", text = change_text, x = L.x + L.w - change_w, y = y - pad_y / 2, w = change_w, h = row_h + pad_y }
    L.change.enabled = not self.creating
    if L.change.enabled then
      self:add_target(L.change.id, L.change.x, L.change.y, L.change.w, L.change.h, function() self:change_location() end)
    end
    y = y + row_h + pad_y
    L.board_y = y
  elseif self.install then
    L.panel = { x = L.x, y = y, w = L.w, h = math.max(row_h, L.message_y - pad_y - y) }
  else
    -- list of choices, scrolled to keep the selection visible
    L.list = { x = L.x, y = y, w = L.w, h = math.max(row_h, L.message_y - pad_y - y) }
    self.visible_rows = math.max(1, math.floor(L.list.h / row_h))
    local items = self:get_list()
    self.first_row = common.clamp(self.first_row, 1, math.max(1, #items - self.visible_rows + 1))
    L.rows = {}
    for i = self.first_row, math.min(#items, self.first_row + self.visible_rows - 1) do
      local row = { item = items[i], index = i, id = "row:" .. items[i].key,
        x = L.x, y = y + (i - self.first_row) * row_h, w = L.w, h = row_h }
      table.insert(L.rows, row)
      self:add_target(row.id, row.x, row.y, row.w, row.h, function(clicks)
        self.selected = i
        if clicks and clicks >= 2 then self:next() end
        core.redraw = true
      end)
    end
    L.more_below = #items >= self.first_row + self.visible_rows
    L.row_h = row_h
  end

  self.current_layout = L
end


local function draw_border(x, y, w, h, color)
  local t = math.max(1, math.floor(SCALE))
  renderer.draw_rect(x, y, w, t, color)
  renderer.draw_rect(x, y + h - t, w, t, color)
  renderer.draw_rect(x, y, t, h, color)
  renderer.draw_rect(x + w - t, y, t, h, color)
end


function NewProjectView:draw_button(button, primary)
  if not button then return end
  local hovered = button.enabled and self.hovered_id == button.id
  local bg = hovered and style.selection or style.line_highlight
  renderer.draw_rect(button.x, button.y, button.w, button.h, bg)
  if primary and button.enabled then draw_border(button.x, button.y, button.w, button.h, style.caret) end
  local color = not button.enabled and style.dim or (primary and style.accent or style.text)
  common.draw_text(style.font, color, button.text, "center", button.x, button.y, button.w, button.h)
end


-- Cuts text to fit in `width` pixels, ending it with an ellipsis when shortened.
local function truncate(font, text, width)
  if font:get_width(text) <= width then return text end
  local ellipsis = "\u{2026}"
  local cut = text
  while cut ~= "" and font:get_width(cut .. ellipsis) > width do
    cut = cut:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
  end
  return cut ~= "" and (cut:gsub("[%s,]+$", "") .. ellipsis) or ""
end


-- Splits text into lines that fit in `width` pixels.
local function wrap_text(font, text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if line ~= "" and font:get_width(candidate) > width then
      table.insert(lines, line)
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then table.insert(lines, line) end
  return lines
end


function NewProjectView:draw_install_panel(panel)
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local line_h = font:get_height() + pad_y / 2
  local install, platform = self.install, self.install.platform
  local x, y, w = panel.x + pad_x, panel.y + pad_y, panel.w - pad_x * 2
  renderer.draw_rect(panel.x, panel.y, panel.w, panel.h, style.background2)
  core.push_clip_rect(panel.x, panel.y, panel.w, panel.h)

  local function paragraph(text, color)
    for _, line in ipairs(wrap_text(font, text, w)) do
      common.draw_text(font, color, line, "left", x, y, 0, line_h)
      y = y + line_h
    end
    y = y + pad_y / 2
  end

  local version = platform.platform and platform.platform.latest_version or ""
  if install.state == "confirm" then
    paragraph(platform.name .. " is not installed yet", style.accent)
    paragraph("Superduino can download and install it for you. Then you can choose your board.", style.text)
    local boards = examples(platform.board_names)
    if boards then paragraph("Boards in this family: " .. boards .. ".", style.dim) end
    paragraph("Package: " .. platform.id .. (version ~= "" and ("  version " .. version) or "")
      .. "  from " .. platform.vendor_name, style.dim)
    paragraph("Downloading needs an internet connection and can take a few minutes for large families.", style.dim)
  elseif install.state == "running" then
    paragraph("Installing " .. platform.name, style.accent)
    paragraph(install.current or "", style.text)
    -- progress bar of the current download
    local bar_h = math.floor(8 * SCALE)
    local percent = install.progress and install.progress.percent or 0
    renderer.draw_rect(x, y, w, bar_h, style.line_highlight)
    renderer.draw_rect(x, y, math.floor(w * common.clamp(percent, 0, 100) / 100), bar_h, style.caret)
    y = y + bar_h + pad_y
    local p = install.progress
    if p then
      local parts = { string.format("%s of %s", p.done, p.total), string.format("%.0f%%", p.percent) }
      if p.eta then table.insert(parts, (p.eta:gsub("^00m", "")) .. " left") end
      paragraph(table.concat(parts, "   ·   "), style.dim)
    else
      y = y + line_h + pad_y / 2
    end
    if #install.done > 0 then
      paragraph("Done so far:", style.dim)
      local first = math.max(1, #install.done - math.max(1, math.floor((panel.y + panel.h - y) / line_h) - 1) + 1)
      for i = first, #install.done do
        common.draw_text(font, style.dim, "  " .. install.done[i], "left", x, y, 0, line_h)
        y = y + line_h
      end
    end
  else
    paragraph("Could not install " .. platform.name, style.error)
    paragraph(install.error or "Unknown error", style.text)
    paragraph("Check your internet connection and try again.", style.dim)
  end
  core.pop_clip_rect()
end


function NewProjectView:draw()
  self:draw_background(style.background)
  local L = self.current_layout
  if not L then return end
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local step = STEPS[self.step]

  common.draw_text(get_heading_font(), style.text, "New Project", "left", L.x, L.title_y, 0, get_heading_font():get_height())
  common.draw_text(font, style.dim, string.format("Step %d of %d", self.step, #STEPS), "right",
    L.x, L.title_y, L.w, get_heading_font():get_height())

  for i, crumb in ipairs(L.crumbs) do
    local color = style.dim
    if crumb.index == self.step then color = style.accent
    elseif crumb.index < self.step then color = style.text end
    if crumb.id and self.hovered_id == crumb.id then
      renderer.draw_rect(crumb.x - pad_x / 2, crumb.y, crumb.w + pad_x, crumb.h, style.line_highlight)
    end
    common.draw_text(font, color, crumb.text, "left", crumb.x, crumb.y, 0, crumb.h)
    if crumb.index == self.step then
      renderer.draw_rect(crumb.x, crumb.y + crumb.h - math.max(1, SCALE * 2), crumb.w, math.max(1, SCALE * 2), style.caret)
    end
    if i < #L.crumbs then
      common.draw_text(font, style.dim, "  ›  ", "left", crumb.x + crumb.w, crumb.y, 0, crumb.h)
    end
  end

  common.draw_text(font, style.accent, step.question, "left", L.x, L.question_y, 0, font:get_height())
  common.draw_text(font, style.dim, step.hint, "left", L.x, L.hint_y, 0, font:get_height())

  -- input box: search text for list steps, project name for the last step
  local box = L.box
  renderer.draw_rect(box.x, box.y, box.w, box.h, style.background2)
  draw_border(box.x, box.y, box.w, box.h, style.caret)
  local value = self.step == NAME_STEP and self.name or self.filter
  local placeholder = self.step == NAME_STEP and NAME_PLACEHOLDER or LIST_PLACEHOLDER
  local text_x = box.x + pad_x
  core.push_clip_rect(box.x, box.y, box.w, box.h)
  local caret_x = text_x
  if value == "" then
    common.draw_text(font, style.dim, placeholder, "left", text_x, box.y, 0, box.h)
  else
    caret_x = common.draw_text(font, style.text, value, "left", text_x, box.y, 0, box.h)
  end
  if not self.creating and core.active_view == self then
    local caret_h = font:get_height()
    renderer.draw_rect(caret_x, box.y + (box.h - caret_h) / 2, math.max(1, math.floor(SCALE * 2)), caret_h, style.caret)
  end
  core.pop_clip_rect()

  if self.step == NAME_STEP then
    local where = "Finding your sketchbook folder..."
    if self.location then
      local name = self.name == "" and NAME_PLACEHOLDER or self.name
      where = common.home_encode(self.location .. PATHSEP .. name .. PATHSEP .. name .. ".ino")
    end
    local label_end = common.draw_text(font, style.dim, "Will be created as:", "left", L.x, L.location_y, 0, font:get_height())
    local where_x = label_end + pad_x / 2
    where = EmptyView.shorten_path(font, where, L.change.x - pad_x - where_x)
    common.draw_text(font, style.text, where, "left", where_x, L.location_y, 0, font:get_height())
    self:draw_button(L.change, false)

    local board = self:get_board()
    if board then
      local label_end2 = common.draw_text(font, style.dim, "Board:", "left", L.x, L.board_y, 0, font:get_height())
      local name_end = common.draw_text(font, style.text, board.name, "left", label_end2 + pad_x / 2, L.board_y, 0, font:get_height())
      common.draw_text(font, style.dim, board.fqbn, "left", name_end + pad_x, L.board_y, 0, font:get_height())
    end
  elseif L.panel then
    self:draw_install_panel(L.panel)
  elseif L.rows then
    if self.loading then
      common.draw_text(font, style.dim, "Loading boards...", "left", L.x + pad_x, L.list.y, 0, L.row_h)
    elseif #self:get_list() == 0 and self.boards then
      common.draw_text(font, style.dim, "Nothing matches \"" .. self.filter .. "\"", "left", L.x + pad_x, L.list.y, 0, L.row_h)
    end
    for _, row in ipairs(L.rows) do
      if row.index == self.selected then
        renderer.draw_rect(row.x, row.y, row.w, row.h, style.selection)
        renderer.draw_rect(row.x, row.y, math.max(1, math.floor(SCALE * 3)), row.h, style.caret)
      elseif self.hovered_id == row.id then
        renderer.draw_rect(row.x, row.y, row.w, row.h, style.line_highlight)
      end
      local item = row.item
      -- dim text is hard to read on the selection color
      local secondary = row.index == self.selected and style.text or style.dim
      core.push_clip_rect(row.x, row.y, row.w - pad_x, row.h)
      local label_end = common.draw_text(font, style.accent, item.label, "left", row.x + pad_x, row.y, 0, row.h)
      local detail_x = row.x + row.w - pad_x
      if item.detail then
        detail_x = detail_x - font:get_width(item.detail)
        common.draw_text(font, secondary, item.detail, "left", detail_x, row.y, 0, row.h)
      end
      if item.note then
        local note_x = label_end + pad_x
        local note = truncate(font, item.note, detail_x - pad_x - note_x)
        common.draw_text(font, secondary, note, "left", note_x, row.y, 0, row.h)
      end
      core.pop_clip_rect()
    end
    if L.more_below then
      common.draw_text(font, style.dim, "more below...", "right", L.x, L.list.y + L.list.h - L.row_h / 2, L.w - pad_x, L.row_h / 2)
    end
  end

  if self.step == NAME_STEP and self.name ~= "" and not self.creating then
    local problem = self:name_problem()
    if problem then
      common.draw_text(font, style.warn, problem, "left", L.x, L.problem_y, 0, font:get_height() + pad_y)
    end
  end
  if self.message then
    local color = self.message_is_error and style.error or style.dim
    core.push_clip_rect(L.x, L.message_y, L.w, font:get_height() + pad_y)
    common.draw_text(font, color, self.message, "left", L.x, L.message_y, 0, font:get_height() + pad_y)
    core.pop_clip_rect()
  end

  self:draw_button(L.back, false)
  self:draw_button(L.next, L.next_primary)
  local keys_hint = KEYS_HINT
  if self.install then
    keys_hint = ({ confirm = "Enter: install    Esc: not now", failed = "Enter: try again    Esc: go back" })[self.install.state] or ""
  end
  common.draw_text(font, style.dim, keys_hint, "center", L.x, L.buttons_y, L.w, L.next.h)
end


-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

function NewProjectView:get_target_at(x, y)
  for _, target in ipairs(self.targets) do
    if x >= target.x and x < target.x + target.w and y >= target.y and y < target.y + target.h then
      return target
    end
  end
end


function NewProjectView:on_mouse_moved(x, y, dx, dy)
  NewProjectView.super.on_mouse_moved(self, x, y, dx, dy)
  local target = self:get_target_at(x, y)
  local id = target and target.id
  if id ~= self.hovered_id then
    self.hovered_id = id
    self.cursor = target and "hand" or "arrow"
    core.redraw = true
  end
end


function NewProjectView:on_mouse_left()
  NewProjectView.super.on_mouse_left(self)
  self.hovered_id = nil
  core.redraw = true
end


function NewProjectView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return true end
  local target = self:get_target_at(x, y)
  if target then target.run(clicks) end
  return true
end


function NewProjectView:on_mouse_wheel(dy)
  if self.step == NAME_STEP then return end
  local count = #self:get_list()
  local rows = self.visible_rows or 1
  self.first_row = common.clamp(self.first_row - (dy > 0 and 3 or -3), 1, math.max(1, count - rows + 1))
  core.redraw = true
  return true
end


function NewProjectView:on_text_input(text)
  self:type_text(text)
end


---Opens the New Project page, or focuses it when it is already open.
function NewProjectView.open()
  if open_view and core.root_view.root_node:get_node_for_view(open_view) then
    local node = core.root_view.root_node:get_node_for_view(open_view)
    node:set_active_view(open_view)
    return open_view
  end
  open_view = NewProjectView()
  core.root_view:get_active_node_default():add_view(open_view)
  return open_view
end


command.add(NewProjectView, {
  ["new-project:next"] = function(view) view:next() end,
  ["new-project:back"] = function(view) view:back() end,
  ["new-project:backspace"] = function(view) view:backspace() end,
  ["new-project:escape"] = function(view) view:escape() end,
  ["new-project:select-previous"] = function(view) view:move_selection(-1) end,
  ["new-project:select-next"] = function(view) view:move_selection(1) end,
  ["new-project:select-previous-page"] = function(view) view:move_selection(-(view.visible_rows or 1)) end,
  ["new-project:select-next-page"] = function(view) view:move_selection(view.visible_rows or 1) end,
  ["new-project:select-first"] = function(view) view:move_selection(-math.huge) end,
  ["new-project:select-last"] = function(view) view:move_selection(math.huge) end,
  ["new-project:paste"] = function(view) view:type_text(system.get_clipboard() or "") end,
})

keymap.add({
  ["return"] = "new-project:next",
  ["keypad enter"] = "new-project:next",
  ["alt+left"] = "new-project:back",
  ["backspace"] = "new-project:backspace",
  ["escape"] = "new-project:escape",
  ["up"] = "new-project:select-previous",
  ["down"] = "new-project:select-next",
  ["pageup"] = "new-project:select-previous-page",
  ["pagedown"] = "new-project:select-next-page",
  ["home"] = "new-project:select-first",
  ["end"] = "new-project:select-last",
  ["ctrl+v"] = "new-project:paste",
})


return NewProjectView
