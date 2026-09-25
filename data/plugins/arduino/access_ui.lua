-- Commands, confirmations and the welcome screen section for USB access.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local EmptyView = require "core.emptyview"
local access = require "plugins.arduino.access"

local access_ui = {}


-- Shows the command to run in a terminal when no administrator helper is available.
local function offer_terminal_command(what, cmd)
  local text = access.terminal_command(cmd)
  core.nag_view:show(what,
    "Superduino could not show a password dialog (pkexec is not installed).\n"
      .. "You can run this command in a terminal instead:\n" .. text,
    { { text = "Copy Command", default_yes = true }, { text = "Close", default_no = true } },
    function(item)
      if item.text == "Copy Command" then
        system.set_clipboard(text)
        core.log("Copied: %s", text)
      end
    end)
end


---Adds the user to the serial port group after confirmation.
function access_ui.allow_serial_access()
  local s = access.serial
  if s.state == "ok" then
    core.log("Serial ports are already accessible (group %s)", s.group or "?")
    return
  end
  local cmd = access.serial_fix_command()
  if not cmd then
    core.error("Could not tell which group owns the serial ports on this system")
    return
  end
  core.nag_view:show("Allow Serial Port Access",
    "To upload to boards, your user needs to be in the \"" .. s.group .. "\" group.\n"
      .. "This runs as administrator and your computer will ask for your password:\n"
      .. table.concat(cmd, " "),
    { { text = "Allow Access", default_yes = true }, { text = "Cancel", default_no = true } },
    function(item)
      if item.text ~= "Allow Access" then return end
      core.add_thread(function()
        local result, output = access.fix_serial()
        if result == "ok" then
          core.nag_view:show("Almost Done",
            "Access was granted. Log out and back in (or restart the computer) so it takes effect.",
            { { text = "OK", default_yes = true } })
        elseif result == "unavailable" then
          offer_terminal_command("Allow Serial Port Access", cmd)
        elseif result == "cancelled" then
          core.log("Allowing serial port access was cancelled")
        else
          core.error("Could not allow serial port access: %s", output)
        end
      end)
    end)
end


---Runs a platform's setup script after confirmation.
---@param setup { id: string, name: string, version: string, script: string }
function access_ui.run_setup(setup)
  core.nag_view:show("Board Setup: " .. setup.name,
    "This family ships a setup script that lets Linux talk to its boards over USB (udev rules).\n"
      .. "It runs as administrator and your computer will ask for your password.\n"
      .. "Script: " .. common.home_encode(setup.script),
    {
      { text = "Run Setup", default_yes = true },
      { text = "Show Script" },
      { text = "Cancel", default_no = true },
    },
    function(item)
      if item.text == "Show Script" then
        core.root_view:open_doc(core.open_doc(setup.script))
      elseif item.text == "Run Setup" then
        core.add_thread(function()
          local result, output = access.run_setup(setup)
          if result == "ok" then
            core.log("%s: USB setup done", setup.name)
          elseif result == "unavailable" then
            offer_terminal_command("Board Setup: " .. setup.name, { "/bin/bash", setup.script })
          elseif result == "cancelled" then
            core.log("Board setup of %s was cancelled", setup.name)
          else
            core.error("Board setup of %s failed: %s", setup.name, output)
          end
        end)
      end
    end)
end


local function pick_setup()
  local setups = access.pending_setups
  if #setups == 0 then
    core.log("No board setup scripts are waiting to run")
    return
  end
  if #setups == 1 then
    access_ui.run_setup(setups[1])
    return
  end
  local items = {}
  for _, setup in ipairs(setups) do
    table.insert(items, setmetatable({ text = setup.name, info = setup.id .. " " .. setup.version, setup = setup },
      { __tostring = function(i) return i.text .. " " .. i.info end, __lt = function(a, b) return a.text < b.text end }))
  end
  core.command_view:enter("Run Board Setup For", {
    submit = function(_, item)
      if item then access_ui.run_setup(item.setup) end
    end,
    suggest = function(text) return common.fuzzy_match(items, text) end,
  })
end


if access.SUPPORTED then
  command.add(nil, {
    ["arduino:allow-serial-port-access"] = access_ui.allow_serial_access,
    ["arduino:run-board-setup"] = pick_setup,
    ["arduino:check-usb-access"] = access.refresh,
  })

  local function action(id, label, run)
    return { id = id, label = label, run = run }
  end

  EmptyView.add_section({
    id = "arduino-usb",
    title = "USB Access",
    order = 55,
    get_items = function()
      local items = {}
      local s = access.serial
      if s.state == "checking" then
        table.insert(items, { id = "usb:serial", label = "Checking serial port access...", color = style.dim })
      elseif s.state == "ok" then
        table.insert(items, { id = "usb:serial", label = "Serial ports: ready", color = style.good,
          detail = s.group and ("member of " .. s.group) or nil, detail_align = "left" })
      elseif s.state == "missing" then
        table.insert(items, { id = "usb:serial", label = "Serial ports: no access", color = style.warn,
          detail = "needed to upload to most boards", detail_align = "text" })
        table.insert(items, action("usb:allow", "Allow Access...", access_ui.allow_serial_access))
      elseif s.state == "relogin" then
        table.insert(items, { id = "usb:serial", label = "Log out and back in", color = style.warn,
          detail = "to finish allowing serial port access (" .. tostring(s.group) .. ")", detail_align = "text" })
      else
        table.insert(items, { id = "usb:serial", label = "Serial ports: could not check", color = style.dim })
      end
      for _, setup in ipairs(access.pending_setups) do
        table.insert(items, {
          id = "usb:setup:" .. setup.id,
          label = "Set up " .. setup.name .. "...",
          detail = setup.skipped and "skipped earlier" or "USB rules not installed yet",
          detail_align = "text",
          run = function() access_ui.run_setup(setup) end,
        })
      end
      return items
    end,
  })
end


return access_ui
