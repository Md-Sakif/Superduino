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
})


table.insert(EmptyView.actions, 1, { label = "Create New Project...", cmd = "arduino:new-project" })


local function action(id, label, cmd)
  return { id = id, label = label, run = function() command.perform(cmd) end }
end


EmptyView.add_section({
  id = "arduino-cli",
  title = "Arduino CLI",
  order = 50,
  get_items = function()
    local path = cli.path and common.home_encode(cli.path)
    if cli.status == "checking" then
      return {
        { id = "cli:status", label = "Checking arduino-cli...", color = style.dim, detail = path, detail_align = "left" },
      }
    elseif cli.status == "ok" then
      return {
        { id = "cli:status", label = "arduino-cli " .. cli.version, color = style.good, detail = path, detail_align = "left" },
        action("cli:locate", "Change Location...", "arduino:locate-cli"),
      }
    end
    local items = {}
    if cli.status == "missing" then
      table.insert(items, { id = "cli:status", label = "Not found at", color = style.error, detail = path, detail_align = "left" })
    elseif cli.status == "broken" then
      table.insert(items, { id = "cli:status", label = "Not working", color = style.error, detail = path, detail_align = "left" })
    else
      table.insert(items, { id = "cli:status", label = "Not installed", color = style.warn,
        detail = "arduino-cli was not found on this computer", detail_align = "left" })
    end
    table.insert(items, action("cli:locate", "Locate arduino-cli...", "arduino:locate-cli"))
    table.insert(items, action("cli:search", "Search Again", "arduino:search-cli"))
    if cli.status == "not_found" then
      table.insert(items, action("cli:install", "Installation Guide", "arduino:open-cli-install-guide"))
    end
    return items
  end,
})


cli.init()
project.open_pending()

return cli
