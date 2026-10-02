-- The panels above the panel bar (Output, Serial Monitor, Terminal) show one
-- at a time: showing one, however it is shown, hides the others.
local core = require "core"

local bottom_panels = {}

---@type { id: string, is_open: fun(): boolean, close: fun() }[]
bottom_panels.list = {}


---Registers a panel.
---@param panel { id: string, is_open: fun(): boolean, close: fun() }
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


---The id of the panel shown, if any.
function bottom_panels.shown()
  for _, panel in ipairs(bottom_panels.list) do
    local ok, open = pcall(panel.is_open)
    if ok and open then return panel.id end
  end
end


return bottom_panels
