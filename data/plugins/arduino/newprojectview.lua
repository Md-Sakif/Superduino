-- Step-by-step "New Project" page: vendor, architecture, board, the board's
-- settings, then a name. The same page, without the name step, is the Board
-- Settings page of an existing sketch (see `NewProjectView.open_edit`). Panels (install/repair, board indexes, a setting's
-- values, templates) temporarily replace the list or name area; see
-- install_panel.lua, indexes_panel.lua, option_panel.lua, templates_panel.lua.
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
local IndexesPanel = require "plugins.arduino.indexes_panel"
local TemplatesPanel = require "plugins.arduino.templates_panel"
local OptionPanel = require "plugins.arduino.option_panel"

---@class arduino.newprojectview : core.view
---@field super core.view
local NewProjectView = View:extend()

function NewProjectView:__tostring() return "NewProjectView" end

-- Not restored with the session: opening a new project restarts the editor, and
-- a Board Settings page belongs to the sketch it was opened for.
NewProjectView.save_in_workspace = false

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
    title = "Options",
    question = "Adjust the board's settings (optional)",
    hint = "The defaults suit most projects. Change only what you need, e.g. Partition Scheme or PSRAM.",
  },
  {
    title = "Name",
    question = "Give your project a name",
    hint = "Use letters, numbers, _ - or . (no spaces). For example: Blink",
  },
}
local OPTIONS_STEP = 4
local NAME_STEP = #STEPS

-- Board Settings of an existing sketch: the same steps, without the name
local EDIT_STEPS = {}
for i = 1, OPTIONS_STEP - 1 do EDIT_STEPS[i] = STEPS[i] end
EDIT_STEPS[OPTIONS_STEP] = {
  title = "Options",
  question = "Adjust the board's settings",
  hint = "Saved to the sketch's build profile (sketch.yaml). To use another board, click a step above.",
}

local LIST_PLACEHOLDER = "Type to search..."
local NAME_PLACEHOLDER = "MyProject"
local KEYS_HINT = "Enter: continue    Esc: go back"
local OPTIONS_KEYS_HINT = "←/→: change    Space: all choices    Enter: continue"
local EDIT_KEYS_HINT = "←/→: change    Space: all choices    "


---@type arduino.newprojectview?
local open_view
-- Board Settings pages by sketch folder
local edit_views = {}


---@param options? { edit?: { dir: string, sketch: table } } `edit`: the Board Settings
---page of the sketch in `dir` (`sketch` as returned by `project.read_sketch`).
function NewProjectView:new(options)
  NewProjectView.super.new(self)
  self.edit = options and options.edit
  self.step = 1
  self.choice = {} -- selected key for each list step
  self.filter = ""
  self.selected = 1
  self.first_row = 1
  self.name = ""
  self.location = nil
  self.template = nil -- nil means the empty sketch
  self.board_options = nil -- { fqbn, loading, options?, error?, skip? } of the chosen board
  self.option_choice = {} -- changed board settings: value by option name
  self.boards = nil
  self.platforms = {}
  self.panel = nil -- InstallPanel, IndexesPanel, OptionPanel or TemplatesPanel
  self.index = { state = "idle" } -- board list refresh: idle, updating, updated, offline, failed
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
  return self.edit and ("Board: " .. common.basename(self.edit.dir)) or "New Project"
end


function NewProjectView:steps()
  return self.edit and EDIT_STEPS or STEPS
end


function NewProjectView:supports_text_input()
  if self.creating then return false end
  if self.panel then return self.panel.wants_text ~= nil and self.panel:wants_text() end
  return true
end


function NewProjectView:try_close(do_close)
  if self.panel and self.panel.on_close then self.panel:on_close() end
  if open_view == self then open_view = nil end
  if self.edit and edit_views[self.edit.dir] == self then edit_views[self.edit.dir] = nil end
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
    elseif self.edit and not self.edit.started then
      self:start_edit()
    else
      self:enter_step(self.step)
      -- Board Settings keep the board list as it is unless Refresh is used
      if not self.edit then self:refresh_index() end
    end
    core.redraw = true
  end)
end


---Downloads the latest board list in the background, then updates the lists.
function NewProjectView:refresh_index()
  if self.index.state == "updating" then return end
  self.index = { state = "updating" }
  core.redraw = true
  core.add_thread(function()
    local ok, err = project.update_index()
    if ok then
      self.index = { state = "updated", time = os.time() }
      local platforms = project.load_platforms()
      if platforms then
        self.platforms = platforms
        self.list_key = nil
        self:keep_selection()
      end
    else
      local explanation, is_network = cli.explain_error(err)
      self.index = { state = is_network and "offline" or "failed", explanation = explanation, error = err,
        age = project.index_age() }
      core.warn("Could not refresh the board list: %s", err)
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
-- { id, name, vendor, vendor_name, installed_version?, board_names, platform?, incomplete?,
--   deprecated?, deprecation? }
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
    else
      family = { id = platform.id, name = platform.name, vendor = platform.vendor, vendor_name = platform.vendor_name,
        installed_version = platform.installed_version, board_names = platform.board_names, platform = platform }
      families[platform.id] = family
      table.insert(order, family)
    end
    if platform.deprecated then
      -- listed (dimmed, last) rather than hidden; the index puts the reason in the name
      family.deprecated = true
      local reason = family.name:match("^%[DEPRECATED%s*%-?%s*([^%]]*)%]")
      family.deprecation = reason and reason ~= "" and reason or nil
      family.name = family.name:gsub("^%[DEPRECATED[^%]]*%]%s*", "")
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
        item = { key = family.vendor, label = family.vendor_name, count = 0, installed = false, deprecated = true }
        seen[family.vendor] = item
        table.insert(items, item)
      end
      item.count = item.count + #family.board_names
      item.installed = item.installed or family.installed_version ~= nil
      -- a vendor counts as deprecated only when all its families are
      item.deprecated = item.deprecated and family.deprecated == true
    end
    for _, item in ipairs(items) do
      item.note = count_boards(item.count)
      item.detail = item.installed and "installed" or "not installed"
      if item.deprecated then
        item.detail = item.installed and "installed, deprecated" or "deprecated"
        item.color = style.dim
      end
    end
    table.sort(items, function(a, b)
      -- Arduino first, since it is what most people start with, then installed ones; deprecated last
      if a.deprecated ~= b.deprecated then return not a.deprecated end
      if (a.key == "arduino") ~= (b.key == "arduino") then return a.key == "arduino" end
      if a.installed ~= b.installed then return a.installed end
      return a.label:lower() < b.label:lower()
    end)
  elseif step == 2 then
    for _, family in ipairs(self:get_families()) do
      if family.vendor == self.choice[1] then
        local detail = family.installed_version and ("installed " .. family.installed_version) or "not installed"
        if family.deprecated then detail = detail .. ", deprecated" end
        if family.incomplete then detail = "half installed - needs repair" end
        table.insert(items, {
          key = family.id,
          label = family.name,
          note = family.deprecated and family.deprecation or InstallPanel.examples(family.board_names),
          detail = detail,
          color = family.deprecated and style.dim or nil,
          detail_color = family.incomplete and style.error or nil,
          installed = family.installed_version ~= nil and not family.incomplete,
          deprecated = family.deprecated == true,
          family = family,
        })
      end
    end
    table.sort(items, function(a, b)
      if a.deprecated ~= b.deprecated then return not a.deprecated end
      if a.installed ~= b.installed then return a.installed end
      return a.label:lower() < b.label:lower()
    end)
  elseif step == 3 then
    for _, board in ipairs(self.boards or {}) do
      if board.arch == self.choice[2] then
        table.insert(items, { key = board.fqbn, label = board.name, detail = board.fqbn, board = board, installed = true })
      end
    end
  elseif step == OPTIONS_STEP then
    for _, option in ipairs(self:get_options() or {}) do
      local value = self:option_value(option)
      local changed = value ~= option.default
      table.insert(items, {
        key = option.option,
        label = option.label,
        note = changed and ("changed, default: " .. self:value_label(option, option.default)) or nil,
        detail = self:value_label(option, value),
        detail_color = changed and style.accent or nil,
        option = option,
      })
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
  if self.step == OPTIONS_STEP then
    -- a few rows whose values change in place: not cached, not filtered
    self.list_key = nil
    self.list = self:get_step_items(OPTIONS_STEP)
    return self.list
  end
  local key = self.step .. "\0" .. tostring(self.choice[1]) .. "\0" .. tostring(self.choice[2]) .. "\0" .. self.filter
  if self.list_key ~= key or self.list_boards ~= self.boards or self.list_platforms ~= self.platforms then
    self.list_key, self.list_boards, self.list_platforms = key, self.boards, self.platforms
    self.list = filter_items(self:get_step_items(self.step), self.filter)
  end
  return self.list
end


-- Keeps the same item selected after the list was reloaded.
function NewProjectView:keep_selection()
  if self.step >= OPTIONS_STEP then return end
  local key = self.list and self.list[self.selected] and self.list[self.selected].key or self.choice[self.step]
  self.list_key = nil
  for i, item in ipairs(self:get_list()) do
    if item.key == key then self.selected = i return end
  end
  self.selected = math.min(self.selected, math.max(1, #self:get_list()))
end


function NewProjectView:get_board()
  for _, item in ipairs(self:get_step_items(3)) do
    if item.key == self.choice[3] then return item.board end
  end
end


-- Short text describing what was chosen at a list step.
function NewProjectView:choice_label(step)
  if step == OPTIONS_STEP then
    local options = self:get_options()
    if not options then return nil end
    if #options == 0 then return "No options" end
    local changed = 0
    for _, option in ipairs(options) do
      if self:option_value(option) ~= option.default then changed = changed + 1 end
    end
    return changed == 0 and "Default options" or (changed == 1 and "1 option changed" or (changed .. " options changed"))
  end
  for _, item in ipairs(self:get_step_items(step)) do
    if item.key == self.choice[step] then return item.label end
  end
end


-------------------------------------------------------------------------------
-- Board settings (the options part of the fqbn)
-------------------------------------------------------------------------------

---Settings of the chosen board, or nil while they load or when they could not be loaded.
---@return arduino.board_option[]?
function NewProjectView:get_options()
  local board, state = self:get_board(), self.board_options
  if board and state and state.fqbn == board.fqbn then return state.options end
end


function NewProjectView:option_value(option)
  return self.option_choice[option.option] or option.default
end


function NewProjectView:value_label(option, value)
  for _, entry in ipairs(option.values) do
    if entry.value == value then return entry.label end
  end
  return value
end


function NewProjectView:set_option_value(option, value)
  self.option_choice[option.option] = value ~= option.default and value or nil
  core.redraw = true
end


---Changes the selected setting to its previous (-1) or next (1) value.
function NewProjectView:step_option_value(delta)
  local item = self.step == OPTIONS_STEP and not self.panel and self:get_list()[self.selected]
  if not item then return end
  local option, current = item.option, self:option_value(item.option)
  for i, entry in ipairs(option.values) do
    if entry.value == current then
      local new = option.values[common.clamp(i + delta, 1, #option.values)]
      self:set_option_value(option, new.value)
      return
    end
  end
end


function NewProjectView:open_option()
  local item = self.step == OPTIONS_STEP and not self.panel and self:get_list()[self.selected]
  if item then self:open_panel(OptionPanel.new(self, item.option)) end
end


function NewProjectView:reset_options()
  self.option_choice = {}
  core.redraw = true
end


---The chosen board's fqbn with its changed settings.
function NewProjectView:get_fqbn()
  local board = self:get_board()
  return board and project.fqbn_with_options(board.fqbn, self:get_options(), self.option_choice)
end


---Loads the settings of the chosen board in the background.
---@param skip_if_none? boolean Go on to the name step when the board has no settings
function NewProjectView:load_options(skip_if_none)
  -- Board Settings end with the options step, even without options
  if self.edit then skip_if_none = false end
  local board = self:get_board()
  if not board then return end
  local state = self.board_options
  if state and state.fqbn == board.fqbn and not state.error then
    if state.loading then
      state.skip = state.skip or skip_if_none
    elseif skip_if_none and #state.options == 0 then
      self:skip_options()
    end
    return
  end
  state = { fqbn = board.fqbn, loading = true, skip = skip_if_none }
  self.board_options = state
  core.redraw = true
  core.add_thread(function()
    local options, err = project.load_board_options(board.fqbn)
    state.loading, state.options, state.error = false, options, err
    if options and self.board_options == state then
      -- settings read from a sketch may name the default value; that is no change
      for _, option in ipairs(options) do
        if self.option_choice[option.option] == option.default then self.option_choice[option.option] = nil end
      end
    end
    if err then core.warn("Could not load the settings of %s: %s", board.name, err) end
    if self.board_options == state and state.skip and options and #options == 0
      and self.step == OPTIONS_STEP and not self.panel then
      self:skip_options()
    end
    core.redraw = true
  end)
end


-- Boards without settings go straight from the board step to the name step.
function NewProjectView:skip_options()
  self.choice[OPTIONS_STEP] = "none"
  self:enter_step(NAME_STEP)
end


function NewProjectView:retry_options()
  self.board_options = nil
  self:load_options()
end


-------------------------------------------------------------------------------
-- Board Settings of an existing sketch
-------------------------------------------------------------------------------

-- Starts with the sketch's board and settings chosen, on the options step (or
-- the step asked for by `open_edit`).
function NewProjectView:start_edit()
  local edit = self.edit
  edit.started = true
  local fqbn = edit.sketch.profile and edit.sketch.profile.fqbn
  if not fqbn then
    self:enter_step(1)
    return
  end
  local base, options = project.split_fqbn(fqbn)
  local vendor, arch = base:match("^([^:]+):([^:]+):")
  self.choice[1], self.choice[2] = vendor, vendor and (vendor .. ":" .. arch)
  for _, board in ipairs(self.boards or {}) do
    if board.fqbn == base then
      self.choice[3], self.option_choice = base, options
      self:enter_step(edit.start_step or OPTIONS_STEP)
      return
    end
  end
  -- e.g. a sketch made on another computer
  self:enter_step(self.choice[2] and 2 or 1)
  self:set_message("The board " .. base .. " is not installed on this computer. Install its family, "
    .. "or choose another board.", true)
end


---Whether the chosen board or settings differ from what sketch.yaml has.
function NewProjectView:board_changed()
  local profile = self.edit.sketch.profile
  return not (profile and profile.fqbn) or self:get_fqbn() ~= profile.fqbn
end


---Writes the chosen board to sketch.yaml ("Apply"), then closes the page when `close`.
function NewProjectView:save_board(close)
  local fqbn = self:get_fqbn()
  if not fqbn or self.creating then return end
  local function finish()
    if not close then return end
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then node:close_view(core.root_view.root_node, self) end
  end
  if not self:board_changed() then return finish() end
  -- never overwrite edits of sketch.yaml that are not saved yet
  local path = self.edit.sketch.path or (self.edit.dir .. PATHSEP .. "sketch.yaml")
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == path and doc:is_dirty() then
      self:set_message(common.basename(path) .. " has unsaved changes in the editor. Save or undo them, "
        .. "then apply again.", true)
      return
    end
  end
  self.creating = true
  self:set_message("Saving...", false)
  core.add_thread(function()
    local name, err = project.save_board(self.edit.dir, fqbn)
    self.creating = false
    if not name then
      local explanation = cli.explain_error(err)
      self:set_message("Could not save the board: " .. (explanation and (explanation .. " ") or "") .. tostring(err), true)
      return
    end
    core.log("%s now uses %s (profile %s)", common.basename(self.edit.dir), fqbn, name)
    -- what is saved now (the profile may have been renamed or created)
    self.edit.sketch = project.read_sketch(self.edit.dir) or self.edit.sketch
    -- show it in sketch.yaml when it is open
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename == self.edit.sketch.path and not doc:is_dirty() then doc:reload() end
    end
    self:set_message("Saved to " .. common.basename(self.edit.sketch.path or "sketch.yaml") .. ".", false)
    finish()
  end)
end


-------------------------------------------------------------------------------
-- Navigation
-------------------------------------------------------------------------------

function NewProjectView:enter_step(step)
  self.step = step
  self.filter = ""
  self.selected, self.first_row = 1, 1
  if step == OPTIONS_STEP then
    self:load_options()
  elseif step < OPTIONS_STEP then
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
  if self.step == OPTIONS_STEP then
    local state = self.board_options
    if state and state.loading then return end
    if self.edit then
      self:save_board(true)
      return
    end
    -- also when the settings could not be loaded: the board's defaults are used
    self.choice[OPTIONS_STEP] = "done"
    self.message = nil
    self:enter_step(NAME_STEP)
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
    if self.step == 3 then
      self.template = nil
      self.option_choice = {}
    end
  end
  self.message = nil
  self:enter_step(self.step + 1)
  if self.step == OPTIONS_STEP then self:load_options(true) end
end


function NewProjectView:back()
  if self.panel then
    self.panel:escape()
    return
  end
  if self.creating or self.step == 1 then return end
  self.message = nil
  local options = self:get_options()
  if self.step == NAME_STEP and options and #options == 0 then
    -- the options step was skipped on the way here
    self:enter_step(OPTIONS_STEP - 1)
    return
  end
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
  if self.step == OPTIONS_STEP then
    -- no search on the settings step (Space opens the values of a setting)
    return
  elseif self.step == NAME_STEP then
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
  elseif self.step < OPTIONS_STEP and self.filter ~= "" then
    self.filter = ui.remove_last_char(self.filter)
    self.selected, self.first_row = 1, 1
  end
  -- Backspace only deletes text; going back is Esc (or the Back button)
  core.redraw = true
end


function NewProjectView:escape()
  if self.panel then
    self.panel:escape()
  elseif self.step < OPTIONS_STEP and self.filter ~= "" then
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


function NewProjectView:choose_template()
  local board = self:get_board()
  if board then self:open_panel(TemplatesPanel.new(self, board)) end
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
    local ok, err = project.create(path, board, self.template, self:get_fqbn())
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
  local has_options = self.step == OPTIONS_STEP and #self:get_list() > 0
  local hint = KEYS_HINT
  local enter = self.edit and (self:board_changed() and "Enter: apply and close" or "Enter: close")
  if has_options then
    hint = self.edit and (EDIT_KEYS_HINT .. enter) or OPTIONS_KEYS_HINT
  elseif self.edit and self.step == OPTIONS_STEP then
    hint = enter .. "    Esc: go back"
  end
  local buttons = { hint = hint }
  if self.step > 1 then buttons.back = { text = "←  Back", run = function() self:back() end } end
  if self.step == NAME_STEP then
    buttons.next = { text = "Create Project", run = function() self:next() end }
  elseif self.step == OPTIONS_STEP then
    local state = self.board_options
    local ready = not (state and state.loading)
    if self.edit then
      -- only Close until something differs from sketch.yaml
      local changed = self:board_changed()
      buttons.next = { text = changed and "Apply and Close" or "Close", run = function() self:save_board(true) end,
        enabled = ready }
      if changed then
        buttons.extra = { text = "Apply", run = function() self:save_board(false) end, enabled = ready }
      end
    else
      buttons.next = { text = "Next  →", run = function() self:next() end, enabled = ready }
    end
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
  for i, step in ipairs(self:steps()) do
    local text = (i < self.step and i < NAME_STEP and self.choice[i] and self:choice_label(i)) or step.title
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

  -- status and tools: the board list on the vendor and architecture steps,
  -- the board's settings on the options step
  local has_tools = self.step <= 2 or self.step == OPTIONS_STEP
  if has_tools and not self.panel and not self.load_error then
    L.tools_y, L.tools_h = y, row_h
    local right = L.x + L.w
    L.tools = {}
    local tools = {}
    if self.step == OPTIONS_STEP then
      local state = self.board_options
      if state and state.error then
        table.insert(tools, { id = "tool:retry-options", text = "Try Again", run = function() self:retry_options() end })
      elseif #self:get_list() > 0 then
        table.insert(tools, { id = "tool:reset-options", text = "Reset to Defaults", run = function() self:reset_options() end,
          enabled = next(self.option_choice) ~= nil })
      end
    elseif self.step == 1 then
      -- a new board index adds new vendors, so it belongs where vendors are chosen
      table.insert(tools, { id = "tool:indexes", text = "Add Vendor by URL...",
        run = function() self:open_panel(IndexesPanel.new(self)) end })
    end
    if self.step <= 2 then
      table.insert(tools, { id = "tool:refresh", text = "Refresh", run = function() self:refresh_index() end,
        enabled = self.index.state ~= "updating" })
    end
    for _, tool in ipairs(tools) do
      local w = font:get_width(tool.text) + pad_x
      local link = { id = tool.id, text = tool.text, x = right - w, y = y, w = w, h = row_h, enabled = tool.enabled ~= false }
      if link.enabled then self:add_target(link.id, link.x, link.y, link.w, link.h, tool.run) end
      table.insert(L.tools, link)
      right = right - w - pad_x / 2
    end
    L.tools_status_w = right - L.x - pad_x
    y = y + row_h + pad_y / 2
  end

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
  elseif self.step == OPTIONS_STEP then
    -- no search box: the settings of one board fit in the list
    self:layout_list(L, { x = L.x, y = y, w = L.w, h = math.max(row_h, L.message_y - pad_y - y) }, row_h)
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
  y = y + row_h + pad_y
  L.template_y = y
  L.choose_template = side_button("button:template", "Choose Template...", function() self:choose_template() end, y)
end


function NewProjectView:layout_list(L, list, row_h)
  L.list = list
  local items = self:get_list()
  local fits = math.max(1, math.floor(list.h / row_h))
  -- when not all rows fit, the last line is kept for the "more below..." hint
  self.visible_rows = #items > fits and math.max(1, fits - 1) or fits
  self.first_row = common.clamp(self.first_row, 1, math.max(1, #items - self.visible_rows + 1))
  L.rows = {}
  for i = self.first_row, math.min(#items, self.first_row + self.visible_rows - 1) do
    local row = { item = items[i], index = i, id = "row:" .. items[i].key,
      x = L.x, y = list.y + (i - self.first_row) * row_h, w = L.w, h = row_h }
    table.insert(L.rows, row)
    self:add_target(row.id, row.x, row.y, row.w, row.h, function(clicks)
      self.selected = i
      if self.step == OPTIONS_STEP then
        self:open_option()
      elseif clicks and clicks >= 2 then
        self:next()
      end
      core.redraw = true
    end)
  end
  L.more_below = #items >= self.first_row + self.visible_rows
  L.more_y = list.y + self.visible_rows * row_h
  L.row_h = row_h

  -- nothing matches: suggest why and what to do (vendor and architecture steps)
  L.empty = nil
  if #items == 0 and self.boards and not self.loading and self.filter ~= "" and self.step <= 2 then
    local font = style.font
    local pad_x = style.padding.x
    local y = list.y + row_h
    local x = L.x + pad_x + font:get_width("Not listed? ")
    L.empty = { y = y, links = {} }
    local actions = {}
    if self.step == 2 then
      table.insert(actions, { id = "empty:refresh", text = "Refresh the board list", run = function() self:refresh_index() end,
        enabled = self.index.state ~= "updating" })
    end
    table.insert(actions, { id = "empty:indexes", text = "Add Vendor by URL...",
      run = function() self:open_panel(IndexesPanel.new(self)) end })
    for i, action in ipairs(actions) do
      local w = font:get_width(action.text)
      local link = { id = action.id, text = action.text, x = x, y = y, w = w, h = row_h, enabled = action.enabled ~= false }
      if link.enabled then self:add_target(link.id, x, y, w, row_h, action.run) end
      table.insert(L.empty.links, link)
      x = x + w
      if i < #actions then
        link.separator = "  or  "
        x = x + font:get_width(link.separator)
      end
    end
  end
end


-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

-- Text of the board list status line.
function NewProjectView:index_status()
  local index = self.index
  if index.state == "updating" then
    return "Updating the board list...", style.dim
  elseif index.state == "updated" then
    return "Board list updated " .. ui.age(os.time() - index.time) .. ".", style.dim
  elseif index.state == "offline" then
    return "Offline: using the board list from " .. (index.age and ui.age(index.age) or "an earlier download") .. ".",
      style.warn
  elseif index.state == "failed" then
    return "The board list could not be refreshed: " .. (index.explanation or index.error or "?"), style.warn
  end
  return "", style.dim
end


-- Text of the board settings status line.
function NewProjectView:options_status()
  local state, board = self.board_options, self:get_board()
  local fqbn = self:get_fqbn()
  if not state or state.loading or state.error or #state.options == 0 then
    -- explained below the status line
    return "", style.dim
  elseif fqbn and board and fqbn ~= board.fqbn then
    return "Board id: " .. fqbn, style.dim
  end
  return "All settings are at their defaults.", style.dim
end


function NewProjectView:draw()
  self:draw_background(style.background)
  local L = self.current_layout
  if not L then return end
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y
  local steps = self:steps()
  local step = steps[self.step]
  local heading = ui.heading_font()

  common.draw_text(heading, style.text, self.edit and "Board Settings" or "New Project", "left", L.x, L.title_y, 0,
    heading:get_height())
  local corner = string.format("Step %d of %d", self.step, #steps)
  if self.edit then
    local profile = self.edit.sketch.profile
    corner = common.basename(self.edit.dir) .. (profile and ("  ·  profile " .. profile.name) or "  ·  no build profile yet")
  end
  common.draw_text(font, style.dim, corner, "right", L.x, L.title_y, L.w, heading:get_height())

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

  if L.tools then
    local text, color
    if self.step == OPTIONS_STEP then
      text, color = self:options_status()
    else
      text, color = self:index_status()
    end
    common.draw_text(font, color, ui.truncate(font, text, L.tools_status_w), "left", L.x, L.tools_y, 0, L.tools_h)
    for _, link in ipairs(L.tools) do
      if self.hovered_id == link.id and link.enabled then
        renderer.draw_rect(link.x, link.y, link.w, link.h, style.line_highlight)
      end
      common.draw_text(font, link.enabled and style.accent or style.dim, link.text, "center", link.x, link.y, link.w, link.h)
    end
  end

  if L.panel then
    self.panel:draw(L.panel, self.hovered_id)
  elseif L.load_error then
    local W = ui.writer(L.load_error.x, L.load_error.y, L.load_error.w)
    local explanation = cli.explain_error(self.load_error)
    W.paragraph("Could not load the list of boards.", style.error)
    if explanation then W.paragraph(explanation, style.text) end
    W.paragraph("Details: " .. tostring(self.load_error), style.dim)
  elseif self.step == OPTIONS_STEP and L.list then
    self:draw_options(L)
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
    common.draw_text(font, style.dim, ui.truncate(font, self:get_fqbn(), L.x + L.w - name_end - pad_x), "left",
      name_end + pad_x, L.board_y, 0, h)
  end

  local template = self.template
  local template_text = template and template.name or "Empty sketch"
  local note = template and (template.kind == "builtin" and "Superduino starter" or ("example of " .. template.group))
    or "optional: start from a starter or an example"
  local name_end = labelled("Start from:", template_text, style.text, L.template_y, L.choose_template.x, false)
  common.draw_text(font, style.dim, ui.truncate(font, note, L.choose_template.x - pad_x - name_end - pad_x), "left",
    name_end + pad_x, L.template_y, 0, h)
  ui.draw_button(L.choose_template, self.hovered_id == L.choose_template.id, false)
end


function NewProjectView:draw_options(L)
  local font = style.font
  local pad_x = style.padding.x
  local state, board = self.board_options, self:get_board()
  if not state or state.loading then
    common.draw_text(font, style.dim, "Loading the settings of " .. (board and board.name or "the board") .. "...",
      "left", L.x + pad_x, L.list.y, 0, L.row_h)
  elseif state.error then
    local W = ui.writer(L.x + pad_x, L.list.y, L.w - pad_x * 2)
    local explanation = cli.explain_error(state.error)
    W.paragraph("Could not load the settings of " .. (board and board.name or "the board") .. ".", style.warn)
    if explanation then W.paragraph(explanation, style.text) end
    W.paragraph("You can continue: the project then uses the board's default settings. Details: "
      .. tostring(state.error), style.dim)
  elseif #state.options == 0 then
    common.draw_text(font, style.dim, (board and board.name or "This board") .. " has no settings to change.",
      "left", L.x + pad_x, L.list.y, 0, L.row_h)
  end
  ui.draw_rows(L.rows, self.selected, self.hovered_id)
  if L.more_below then
    common.draw_text(font, style.dim, "more below...", "right", L.x, L.more_y, L.w - pad_x, L.row_h)
  end
end


function NewProjectView:draw_list(L)
  local font = style.font
  local pad_x = style.padding.x
  if self.loading then
    common.draw_text(font, style.dim, "Loading boards... (the first time, arduino-cli also downloads its tools)",
      "left", L.x + pad_x, L.list.y, 0, L.row_h)
  elseif #self:get_list() == 0 and self.boards then
    common.draw_text(font, style.dim, "Nothing matches \"" .. self.filter .. "\".", "left", L.x + pad_x, L.list.y, 0, L.row_h)
  end
  if L.empty then
    common.draw_text(font, style.dim, "Not listed? ", "left", L.x + pad_x, L.empty.y, 0, L.row_h)
    for _, link in ipairs(L.empty.links) do
      if self.hovered_id == link.id and link.enabled then
        renderer.draw_rect(link.x, link.y + L.row_h - math.max(1, SCALE), link.w, math.max(1, SCALE), style.accent)
      end
      local link_end = common.draw_text(font, link.enabled and style.accent or style.dim, link.text, "left",
        link.x, link.y, 0, L.row_h)
      if link.separator then
        common.draw_text(font, style.dim, link.separator, "left", link_end, link.y, 0, L.row_h)
      end
    end
  end
  ui.draw_rows(L.rows, self.selected, self.hovered_id)
  if L.more_below then
    common.draw_text(font, style.dim, "more below...", "right", L.x, L.more_y, L.w - pad_x, L.row_h)
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
---@param options? { repair?: string, indexes?: boolean } Open straight into repairing a
---half installed platform (by id) or managing board indexes.
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
  if options.indexes and not view.panel then
    view:open_panel(IndexesPanel.new(view))
  elseif options.repair and not view.panel then
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


---Opens the Board Settings page of a sketch, or focuses it when it is already open.
---@param dir string Sketch folder
---@param step? integer 1 vendor, 2 family, 3 board, 4 options (the default)
function NewProjectView.open_edit(dir, step)
  local view = edit_views[dir]
  local node = view and core.root_view.root_node:get_node_for_view(view)
  if node then
    node:set_active_view(view)
    if step and view.edit.started and not view.panel and not view.creating and view:can_go_to(step) then
      view:enter_step(step)
    end
    return view
  end
  local sketch, err = project.read_sketch(dir)
  if not sketch then
    core.error("Could not read the build profile of %s: %s", dir, tostring(err))
    return
  end
  view = NewProjectView({ edit = { dir = dir, sketch = sketch, start_step = step } })
  edit_views[dir] = view
  core.root_view:get_active_node_default():add_view(view)
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

-- keys of the board settings step; elsewhere they do nothing here, so e.g. Space still types
command.add(function()
  local view = core.active_view
  return view:is(NewProjectView) and view.step == OPTIONS_STEP and not view.panel and not view.creating, view
end, {
  ["new-project:previous-value"] = function(view) view:step_option_value(-1) end,
  ["new-project:next-value"] = function(view) view:step_option_value(1) end,
  ["new-project:open-option"] = function(view) view:open_option() end,
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
  ["left"] = "new-project:previous-value",
  ["right"] = "new-project:next-value",
  ["space"] = "new-project:open-option",
})


return NewProjectView
