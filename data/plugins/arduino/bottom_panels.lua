-- The panels above the panel bar (Output, Serial Monitor, Serial Plotter,
-- Terminal) show one at a time: showing one, however it is shown, hides the others.
local core = require "core"

local bottom_panels = {}

---@alias arduino.bottom_panel { id: string, is_open: fun(): boolean, close: fun(), show?: fun() }

---@type arduino.bottom_panel[]
bottom_panels.list = {}


---Registers a panel.
---@param panel arduino.bottom_panel
function bottom_panels.add(panel)
  table.insert(bottom_panels.list, panel)
end


---Hides every panel but `id`; called by a panel when it is shown.
---@param id string
function bottom_panels.showing(id)
  for _, panel in ipairs(bottom_panels.list) do
    if panel.id ~= id then
      local ok, open = pcall(panel.is_open)
      if ok and open then core.try(panel.close) end
    end
  end
end


---Shows a panel by id (it hides the others).
---@param id string
function bottom_panels.show(id)
  for _, panel in ipairs(bottom_panels.list) do
    if panel.id == id and panel.show then core.try(panel.show) end
  end
end


---The id of the panel shown, if any.
function bottom_panels.shown()
  for _, panel in ipairs(bottom_panels.list) do
    local ok, open = pcall(panel.is_open)
    if ok and open then return panel.id end
  end
end


return bottom_panels
