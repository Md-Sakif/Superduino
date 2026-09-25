-- Step-by-step "New Project" page: vendor, architecture, board, then a name.
-- Panels (install/repair) temporarily replace the list or name area; see
-- install_panel.lua.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local EmptyView = require "core.emptyview"
local cli = require "plugins.arduino.cli"
local project = require "plugins.arduino.project"
local ui = require "plugins.arduino.ui"
local InstallPanel = require "plugins.arduino.install_panel"

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
  self.panel = nil -- e.g. InstallPanel
  self.loading = true
  self.load_error = nil
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
  if self.creating then return false end
  if self.panel then return self.panel.wants_text ~= nil and self.panel:wants_text() end
  return true
end


function NewProjectView:try_close(do_close)
  if self.panel and self.panel.on_close then self.panel:on_close() end
  if open_view == self then open_view = nil end
  NewProjectView.super.try_close(self, do_close)
end


-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

---Loads installed boards and all known platforms. Must be called from a thread.
function NewProjectView:load_data()
  local boards, err = project.load_boards()
  local platforms, platforms_err = project.load_platforms()
  if not platforms then
    -- still usable with the installed boards, e.g. when offline without an index
    core.warn("Could not load the list of installable boards: %s", tostring(platforms_err))
  end
  if (not boards or #boards == 0) and not platforms then
    return false, platforms_err or err
  end
  self.boards, self.platforms = boards or {}, platforms or {}
  self.list_key = nil
  core.redraw = true
  return true
end


function NewProjectView:load()
  self.loading, self.load_error = true, nil
  self.message = nil
  core.redraw = true
  core.add_thread(function()
    local ok, err = self:load_data()
    self.location = self.location or project.sketchbook_dir()
    self.loading = false
    if not ok then
      self.load_error = err
    else
      self:enter_step(self.step)
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

local function count_boards(n)
  return n == 1 and "1 board" or (n .. " boards")
end


-- Families (platforms) of all vendors, installed or not:
-- { id, name, vendor, vendor_name, installed_version?, board_names, platform?, incomplete? }
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
  for _, broken in ipairs(project.incomplete_installs()) do
    if families[broken.id] then families[broken.id].incomplete = true end
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
        local detail = family.installed_version and ("installed " .. family.installed_version) or "not installed"
        if family.incomplete then detail = "half installed - needs repair" end
        table.insert(items, {
          key = family.id,
          label = family.name,
          note = InstallPanel.examples(family.board_names),
          detail = detail,
          detail_color = family.incomplete and style.error or nil,
          installed = family.installed_version ~= nil and not family.incomplete,
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
-- word starting with the text, then any that contain it. Fuzzy matches are only
-- used when nothing else matches: plain fuzzy matching would rank e.g.
-- "Arduino BT" above "Arduino UNO" for "uno" (u-n-o also appear in "arduino").
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
  local result = {}
  for _, group in ipairs(groups) do
    for _, item in ipairs(group) do table.insert(result, item) end
  end
  if #result == 0 then
    table.sort(fuzzy, function(a, b) return a.score > b.score end)
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
  if not self.boards or self.creating or self.panel then return false end
  for i = 1, step - 1 do
    if not self.choice[i] then return false end
  end
  return true
end


function NewProjectView:open_panel(panel)
  self.panel = panel
  self.message = nil
  core.redraw = true
end


---Closes the open panel, optionally showing a message on the page.
function NewProjectView:close_panel(message, is_error)
  self.panel = nil
  self.message, self.message_is_error = message, is_error or false
  self.list_key = nil
  core.redraw = true
end


---Called by the install panel when a family was installed or repaired.
function NewProjectView:finish_install(platform_id, message)
  self.panel = nil
  self.choice[2], self.choice[3] = platform_id, nil
  self:enter_step(3)
  self:set_message(message, false)
end


function NewProjectView:next()
  if self.creating then return end
  if self.panel then
    self.panel:enter()
    return
  end
  if self.load_error then
    self:load()
    return
  end
  if not self.boards then return end
  if self.step == NAME_STEP then
    self:create()
    return
  end
  local item = self:get_list()[self.selected]
  if not item then return end
  if self.step == 2 and not item.installed then
    self:open_panel(InstallPanel.new(self, item.family, item.family.incomplete and "repair" or "install"))
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
  if self.panel then
    self.panel:escape()
    return
  end
  if self.creating or self.step == 1 then return end
  self.message = nil
  self:enter_step(self.step - 1)
end


function NewProjectView:move_selection(delta)
  if self.panel then
    if self.panel.move then self.panel:move(delta) end
    return
  end
  if self.step == NAME_STEP then return end
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
  if self.creating then return end
  if self.panel then
    if self.panel.text_input then self.panel:text_input(text) end
    return
  end
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


function NewProjectView:backspace()
  if self.creating then return end
  if self.panel then
    self.panel:backspace()
    return
  end
  if self.step == NAME_STEP and self.name ~= "" then
    self.name = ui.remove_last_char(self.name)
    self.message = nil
  elseif self.step < NAME_STEP and self.filter ~= "" then
    self.filter = ui.remove_last_char(self.filter)
    self.selected, self.first_row = 1, 1
  else
    self:back()
  end
  core.redraw = true
end


function NewProjectView:escape()
  if self.panel then
    self.panel:escape()
  elseif self.step < NAME_STEP and self.filter ~= "" then
    self.filter = ""
    self.selected, self.first_row = 1, 1
    core.redraw = true
  else
    self:back()
  end
end


-------------------------------------------------------------------------------
-- Name step
-------------------------------------------------------------------------------

function NewProjectView:project_path()
  return self.location and (self.location .. PATHSEP .. self.name)
end


function NewProjectView:location_exists()
  local info = self.location and system.get_file_info(self.location)
  return info ~= nil and info.type == "dir"
end


function NewProjectView:name_problem()
  local problem = project.name_problem(self.name)
  if problem then return problem end
  local path = self:project_path()
  if path and system.get_file_info(path) then
    return common.home_encode(path) .. " already exists; choose another name"
  end
end


function NewProjectView:create_folder()
  if not self.location or self:location_exists() then return end
  local ok, err, path = common.mkdirp(self.location)
  if ok then
    self:set_message("Created the folder " .. common.home_encode(self.location) .. ".", false)
  else
    self:set_message("Could not create " .. tostring(path or self.location) .. ": " .. tostring(err), true)
  end
end


function NewProjectView:change_location()
  -- missing folders are accepted here; the page then offers to create them
  local function use(dir)
    local info = dir and system.get_file_info(dir)
    if info and info.type ~= "dir" then
      self:set_message(common.home_encode(dir) .. " is a file, not a folder.", true)
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
      local dir = common.home_expand(text):gsub("[/\\]+$", "")
      use(common.is_absolute_path(dir) and common.normalize_path(dir) or system.absolute_path(dir) or dir)
    end,
    suggest = function(text)
      return common.home_encode_list(common.dir_path_suggest(common.home_expand(text), self.location or HOME))
    end,
  })
end


function NewProjectView:create()
  if not self:location_exists() then
    self:set_message("The folder " .. common.home_encode(self.location or "?")
      .. " does not exist. Create it with Create Folder, or choose another folder.", true)
    return
  end
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
      local explanation = cli.explain_error(err)
      self:set_message("Could not create the project: " .. (explanation and (explanation .. " ") or "") .. tostring(err), true)
      return
    end
    self:set_message("Created " .. self.name .. ". Opening it...", false)
    project.open(path)
  end)
end


-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

-- Adds a clickable area; hit-testing uses the areas of the latest layout.
function NewProjectView:add_target(id, x, y, w, h, run)
  table.insert(self.targets, { id = id, x = x, y = y, w = w, h = h, run = run })
end


function NewProjectView:update()
  NewProjectView.super.update(self)
  self:layout()
end


-- Creates a button spec and its click target.
function NewProjectView:make_button(id, spec, x, y, h, align_right)
  if not spec then return nil end
  local w = style.font:get_width(spec.text) + style.padding.x * 3
  local button = { id = id, text = spec.text, x = align_right and (x - w) or x, y = y, w = w, h = h,
    enabled = spec.enabled ~= false and spec.run ~= nil, primary = spec.primary }
  if button.enabled then self:add_target(id, button.x, button.y, button.w, button.h, spec.run) end
  return button
end


-- Buttons of the page when no panel is open.
function NewProjectView:page_buttons()
  if self.load_error then
    return { next = { text = "Try Again", run = function() self:load() end },
      hint = "Enter: try again" }
  end
  local buttons = { hint = KEYS_HINT }
  if self.step > 1 then buttons.back = { text = "←  Back", run = function() self:back() end } end
  if self.step == NAME_STEP then
    buttons.next = { text = "Create Project", run = function() self:next() end }
  else
    buttons.next = { text = "Next  →", run = function() self:next() end,
      enabled = self:get_list()[self.selected] ~= nil }
  end
  if not self.boards or self.creating then
    buttons.next.enabled = false
    if buttons.back then buttons.back.enabled = not self.creating end
  end
  return buttons
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
  y = y + ui.heading_font():get_height() + pad_y

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
  y = y + line_h + pad_y

  -- bottom: message line, then buttons
  local button_h = box_h
  L.buttons_y = self.position.y + self.size.y - pad_y * 3 - button_h
  L.message_y = L.buttons_y - pad_y - row_h

  local buttons = self.panel and self.panel:buttons() or self:page_buttons()
  if self.creating and buttons.next then buttons.next.enabled = false end
  L.next = self:make_button("button:next", buttons.next, L.x + L.w, L.buttons_y, button_h, true)
  if L.next then L.next.primary = buttons.next.primary ~= false end
  L.extra = self:make_button("button:extra", buttons.extra, (L.next and L.next.x or L.x + L.w) - pad_x, L.buttons_y, button_h, true)
  L.back = self:make_button("button:back", buttons.back, L.x, L.buttons_y, button_h, false)
  L.hint = (buttons.extra and "") or buttons.hint or ""

  local area = { x = L.x, y = y, w = L.w, h = math.max(row_h, L.message_y - pad_y - y) }
  if self.panel then
    L.panel = area
    if self.panel.layout then
      self.panel:layout(area, function(...) self:add_target(...) end)
    end
  elseif self.load_error then
    L.load_error = area
  else
    L.box = { x = L.x, y = y, w = L.w, h = box_h }
    y = y + box_h + pad_y
    if self.step == NAME_STEP then
      self:layout_name_step(L, y, row_h)
    else
      self:layout_list(L, { x = L.x, y = y, w = L.w, h = math.max(row_h, L.message_y - pad_y - y) }, row_h)
    end
  end

  self.current_layout = L
end


function NewProjectView:layout_name_step(L, y, row_h)
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  L.problem_y = y - pad_y / 2
  y = y + row_h + pad_y / 2

  local function side_button(id, text, run, top)
    local w = font:get_width(text) + pad_x * 2
    local button = { id = id, text = text, x = L.x + L.w - w, y = top - pad_y / 2, w = w, h = row_h + pad_y,
      enabled = not self.creating }
    if button.enabled then self:add_target(id, button.x, button.y, button.w, button.h, run) end
    return button
  end

  L.location_y = y
  L.change = side_button("button:location", "Change Folder...", function() self:change_location() end, y)
  y = y + row_h + pad_y
  if self.location and not self:location_exists() then
    L.missing_y = y
    L.create_folder = side_button("button:create-folder", "Create Folder", function() self:create_folder() end, y)
    y = y + row_h + pad_y
  end
  L.board_y = y
end


function NewProjectView:layout_list(L, list, row_h)
  L.list = list
  self.visible_rows = math.max(1, math.floor(list.h / row_h))
  local items = self:get_list()
  self.first_row = common.clamp(self.first_row, 1, math.max(1, #items - self.visible_rows + 1))
  L.rows = {}
  for i = self.first_row, math.min(#items, self.first_row + self.visible_rows - 1) do
    local row = { item = items[i], index = i, id = "row:" .. items[i].key,
      x = L.x, y = list.y + (i - self.first_row) * row_h, w = L.w, h = row_h }
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


-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

function NewProjectView:draw()
  self:draw_background(style.background)
  local L = self.current_layout
  if not L then return end
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local step = STEPS[self.step]
  local heading = ui.heading_font()

  common.draw_text(heading, style.text, "New Project", "left", L.x, L.title_y, 0, heading:get_height())
  common.draw_text(font, style.dim, string.format("Step %d of %d", self.step, #STEPS), "right",
    L.x, L.title_y, L.w, heading:get_height())

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

  if L.panel then
    self.panel:draw(L.panel, self.hovered_id)
  elseif L.load_error then
    local W = ui.writer(L.load_error.x, L.load_error.y, L.load_error.w)
    local explanation = cli.explain_error(self.load_error)
    W.paragraph("Could not load the list of boards.", style.error)
    if explanation then W.paragraph(explanation, style.text) end
    W.paragraph("Details: " .. tostring(self.load_error), style.dim)
  elseif L.box then
    local value = self.step == NAME_STEP and self.name or self.filter
    local placeholder = self.step == NAME_STEP and NAME_PLACEHOLDER or LIST_PLACEHOLDER
    ui.draw_text_box(L.box, value, placeholder, not self.creating and core.active_view == self)
    if self.step == NAME_STEP then
      self:draw_name_step(L)
    else
      self:draw_list(L)
    end
  end

  if self.message then
    local color = self.message_is_error and style.error or style.dim
    core.push_clip_rect(L.x, L.message_y, L.w, font:get_height() + pad_y)
    common.draw_text(font, color, self.message, "left", L.x, L.message_y, 0, font:get_height() + pad_y)
    core.pop_clip_rect()
  end

  ui.draw_button(L.back, self.hovered_id == "button:back", false)
  ui.draw_button(L.extra, self.hovered_id == "button:extra", false)
  ui.draw_button(L.next, self.hovered_id == "button:next", L.next and L.next.primary)
  common.draw_text(font, style.dim, L.hint, "center", L.x, L.buttons_y, L.w, L.next and L.next.h or font:get_height())
end


function NewProjectView:draw_name_step(L)
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local h = font:get_height()

  if self.name ~= "" and not self.creating then
    local problem = self:name_problem()
    if problem then common.draw_text(font, style.warn, problem, "left", L.x, L.problem_y, 0, h + pad_y) end
  end

  local function labelled(label, value, value_color, y, right_limit, shorten)
    local label_end = common.draw_text(font, style.dim, label, "left", L.x, y, 0, h)
    local value_x = label_end + pad_x / 2
    local max_w = right_limit - pad_x - value_x
    value = shorten and EmptyView.shorten_path(font, value, max_w) or ui.truncate(font, value, max_w)
    return common.draw_text(font, value_color, value, "left", value_x, y, 0, h)
  end

  local where = "Finding your sketchbook folder..."
  if self.location then
    local name = self.name == "" and NAME_PLACEHOLDER or self.name
    where = common.home_encode(self.location .. PATHSEP .. name .. PATHSEP .. name .. ".ino")
  end
  labelled("Will be created as:", where, style.text, L.location_y, L.change.x, true)
  ui.draw_button(L.change, self.hovered_id == L.change.id, false)

  if L.missing_y then
    labelled("Folder missing:", common.home_encode(self.location) .. " does not exist yet", style.warn,
      L.missing_y, L.create_folder.x, false)
    ui.draw_button(L.create_folder, self.hovered_id == L.create_folder.id, false)
  end

  local board = self:get_board()
  if board then
    local name_end = labelled("Board:", board.name, style.text, L.board_y, L.x + L.w, false)
    common.draw_text(font, style.dim, board.fqbn, "left", name_end + pad_x, L.board_y, 0, h)
  end

end


function NewProjectView:draw_list(L)
  local font = style.font
  local pad_x = style.padding.x
  if self.loading then
    common.draw_text(font, style.dim, "Loading boards... (the first time, arduino-cli also downloads its tools)",
      "left", L.x + pad_x, L.list.y, 0, L.row_h)
  elseif #self:get_list() == 0 and self.boards then
    common.draw_text(font, style.dim, "Nothing matches \"" .. self.filter .. "\"", "left", L.x + pad_x, L.list.y, 0, L.row_h)
  end
  ui.draw_rows(L.rows, self.selected, self.hovered_id)
  if L.more_below then
    common.draw_text(font, style.dim, "more below...", "right", L.x, L.list.y + L.list.h - L.row_h / 2, L.w - pad_x, L.row_h / 2)
  end
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
  if self.panel then
    if self.panel.wheel then self.panel:wheel(dy) end
    return true
  end
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
---@param options? { repair?: string } Open straight into repairing a half installed
---platform (by id).
function NewProjectView.open(options)
  local view = open_view
  if view and core.root_view.root_node:get_node_for_view(view) then
    core.root_view.root_node:get_node_for_view(view):set_active_view(view)
  else
    view = NewProjectView()
    open_view = view
    core.root_view:get_active_node_default():add_view(view)
  end
  options = options or {}
  if options.repair and not view.panel then
    local name = options.repair
    for _, broken in ipairs(project.incomplete_installs()) do
      if broken.id == options.repair then name = broken.name end
    end
    local vendor = options.repair:match("^([^:]+)")
    view.choice[1] = vendor
    view.step = 2
    view:open_panel(InstallPanel.new(view, { id = options.repair, name = name, vendor_name = vendor,
      board_names = {} }, "repair"))
  end
  return view
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
