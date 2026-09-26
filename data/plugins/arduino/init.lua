-- mod-version:4
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local EmptyView = require "core.emptyview"
local cli = require "plugins.arduino.cli"
local project = require "plugins.arduino.project"
local NewProjectView = require "plugins.arduino.newprojectview"
local access = require "plugins.arduino.access"
local managed = require "plugins.arduino.managed_cli"
local BoardPanel = require "plugins.arduino.board_panel"
require "plugins.arduino.access_ui"


local function open_url(url)
  if PLATFORM == "Windows" then
    system.exec(string.format("start \"\" %q", url))
  elseif PLATFORM == "Mac OS X" then
    system.exec(string.format("open %q", url))
  else
    system.exec(string.format("xdg-open %q", url))
  end
end


local function use_path(path)
  local info = path and system.get_file_info(path)
  if not info or info.type ~= "file" then
    core.error("Not a file: %s", path or "")
    return
  end
  cli.set_path(path)
end


local function locate(use_dialog)
  local start_dir = cli.path and common.dirname(cli.path) or HOME
  if use_dialog then
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
        use_path(result[1])
      elseif status == "error" then
        core.error("Error while opening dialog: %s", result or "")
      end
    end, {
      title = "Locate arduino-cli",
      default_location = start_dir,
    })
    return
  end
  core.command_view:enter("Locate arduino-cli", {
    text = cli.path and common.home_encode(cli.path)
      or (start_dir and common.home_encode(start_dir) .. PATHSEP),
    submit = function(text)
      use_path(common.home_expand(text))
    end,
    suggest = function(text)
      return common.home_encode_list(common.path_suggest(common.home_expand(text)))
    end,
  })
end


-- the open project is an Arduino sketch
command.add(function() return BoardPanel.current() ~= nil end, {
  ["arduino:board-settings"] = function()
    if cli.status ~= "ok" then
      core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
      return
    end
    NewProjectView.open_edit(core.root_project().path)
  end,
})


command.add(nil, {
  ["arduino:new-project"] = function()
    if cli.status ~= "ok" then
      core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
      return
    end
    NewProjectView.open()
  end,

  ["arduino:locate-cli"] = function()
    locate(config.use_system_file_picker)
  end,

  ["arduino:search-cli"] = function()
    local path = cli.search()
    if path then
      core.log("Found arduino-cli at %s", path)
    else
      core.warn("arduino-cli was not found in PATH or the usual install locations")
    end
  end,

  ["arduino:open-cli-install-guide"] = function()
    open_url(cli.INSTALL_URL)
  end,

  ["arduino:download-cli"] = function()
    managed.download()
  end,

  ["arduino:manage-board-indexes"] = function()
    if cli.status ~= "ok" then
      core.error("arduino-cli is not available; see the Arduino CLI section on the welcome screen")
      return
    end
    NewProjectView.open({ indexes = true })
  end,

  ["arduino:repair-platform"] = function()
    local broken = project.incomplete_installs()
    if #broken == 0 then
      core.log("No board families need repairing")
    elseif #broken == 1 then
      NewProjectView.open({ repair = broken[1].id })
    else
      local items = {}
      for _, b in ipairs(broken) do
        table.insert(items, setmetatable({ text = b.name, info = b.id },
          { __tostring = function(i) return i.text .. " " .. i.info end, __lt = function(a, c) return a.text < c.text end }))
      end
      core.command_view:enter("Repair Board Family", {
        submit = function(_, item) if item then NewProjectView.open({ repair = item.info }) end end,
        suggest = function(text) return common.fuzzy_match(items, text) end,
      })
    end
  end,
})

command.add(function() return managed.busy() end, {
  ["arduino:cancel-cli-download"] = function() managed.cancel() end,
})


table.insert(EmptyView.actions, 1, { label = "Create New Project...", cmd = "arduino:new-project" })


local function action(id, label, cmd)
  return { id = id, label = label, run = function() command.perform(cmd) end }
end


local function run(id, label, fn)
  return { id = id, label = label, run = fn }
end


-- Rows describing a running or failed download of the managed arduino-cli.
local function download_rows()
  local s = managed.status
  if s.state == "idle" then return {} end
  if s.state == "failed" then
    local explanation = cli.explain_error((s.error or "") .. " " .. (s.details or ""))
    return {
      { id = "cli:download", label = "Download failed", color = style.error,
        detail = (explanation or s.error or "") .. (s.details and ("  Details: " .. s.details) or ""), detail_align = "text" },
      action("cli:download-again", "Try Again", "arduino:download-cli"),
    }
  end
  local text = ({ checking = "Finding the latest arduino-cli...", verifying = "Checking the download...",
    installing = "Installing arduino-cli " .. tostring(s.version) .. "..." })[s.state]
  if s.state == "downloading" then
    text = "Downloading arduino-cli " .. tostring(s.version) .. "..."
    if s.total and s.total > 0 then
      local detail = string.format("%.0f%%  (%.1f of %.1f MB)", 100 * (s.done or 0) / s.total,
        (s.done or 0) / 1e6, s.total / 1e6)
      return {
        { id = "cli:download", label = text, color = style.accent, detail = detail, detail_align = "text" },
        action("cli:cancel", "Cancel Download", "arduino:cancel-cli-download"),
      }
    end
  end
  return {
    { id = "cli:download", label = text, color = style.accent },
    action("cli:cancel", "Cancel Download", "arduino:cancel-cli-download"),
  }
end


EmptyView.add_section({
  id = "arduino-cli",
  title = "Arduino CLI",
  order = 50,
  get_items = function()
    local items = {}
    local path = cli.path and common.home_encode(cli.path)
    if cli.status == "checking" then
      table.insert(items, { id = "cli:status", label = "Checking arduino-cli...", color = style.dim, detail = path,
        detail_align = "left" })
    elseif cli.status == "ok" then
      table.insert(items, { id = "cli:status", label = "arduino-cli " .. cli.version, color = style.good,
        detail = (cli.managed and "managed by Superduino: " or "") .. path, detail_align = "left" })
    elseif cli.status == "missing" then
      table.insert(items, { id = "cli:status", label = "Not found at", color = style.error, detail = path, detail_align = "left" })
    elseif cli.status == "broken" then
      table.insert(items, { id = "cli:status", label = "Not working", color = style.error, detail = path, detail_align = "left" })
    else
      table.insert(items, { id = "cli:status", label = "Not installed", color = style.warn,
        detail = "Superduino needs arduino-cli to work with boards", detail_align = "text" })
    end

    local downloading = download_rows()
    for _, row in ipairs(downloading) do table.insert(items, row) end
    if managed.busy() or cli.status == "checking" then return items end

    -- both ways are always offered: Superduino manages arduino-cli, or the user points to their own
    if cli.status == "ok" and cli.managed then
      table.insert(items, action("cli:update", "Update arduino-cli", "arduino:download-cli"))
      table.insert(items, action("cli:locate", "Use My Own arduino-cli...", "arduino:locate-cli"))
    elseif cli.status == "ok" then
      table.insert(items, action("cli:locate", "Change Location...", "arduino:locate-cli"))
      table.insert(items, action("cli:manage", "Let Superduino Manage arduino-cli", "arduino:download-cli"))
    else
      if #downloading == 0 then
        table.insert(items, action("cli:manage", "Download arduino-cli for Me", "arduino:download-cli"))
      end
      table.insert(items, action("cli:locate", "Locate My Own arduino-cli...", "arduino:locate-cli"))
      table.insert(items, action("cli:search", "Search Again", "arduino:search-cli"))
      table.insert(items, action("cli:install", "Installation Guide", "arduino:open-cli-install-guide"))
    end
    return items
  end,
})


-- Only shown when something needs fixing.
EmptyView.add_section({
  id = "arduino-attention",
  title = "Needs Attention",
  order = 45,
  get_items = function()
    local items = {}
    for _, broken in ipairs(project.incomplete_installs()) do
      table.insert(items, { id = "attention:" .. broken.id, label = broken.name .. " is only half installed",
        color = style.error, detail = "its boards will not work until it is repaired", detail_align = "text" })
      table.insert(items, run("attention:repair:" .. broken.id, "Repair " .. broken.name .. "...",
        function() NewProjectView.open({ repair = broken.id }) end))
    end
    return items
  end,
})


BoardPanel.dock()
table.insert(cli.on_checked, access.refresh)
cli.init()
project.open_pending()

return cli
