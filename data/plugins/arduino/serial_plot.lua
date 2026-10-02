-- The serial plotter's data: numbers in the lines the board prints, as named
-- series over the sample number. Lines are read like the Arduino IDE does:
-- fields separated by spaces, tabs or commas, each "label:value" or a bare
-- value (named "Value 1", "Value 2"... by position). Lines with other text are
-- messages, not samples.
local core = require "core"
local storage = require "core.storage"
local monitor = require "plugins.arduino.serial_monitor"

local plot = {}

---Samples kept; older ones are dropped.
plot.MAX_SAMPLES = 5000
---How many of the last samples can be shown.
plot.WINDOWS = { 50, 100, 200, 500, 1000, 2000, 5000 }
plot.DEFAULT_WINDOW = 100

---@class arduino.plot_series
---@field name string
---@field color integer Index into the view's palette, in order of appearance
---@field values table<integer, number> By sample number
---@field hidden boolean
---@field last? number Latest value

---@type arduino.plot_series[]
plot.series = {}
local by_name = {}
---Number of the latest sample (0 before the first), and of the oldest kept.
plot.count, plot.first = 0, 1
---The sample number the view is frozen at, while paused.
plot.paused_at = nil

local STORAGE_MODULE, STORAGE_KEY = "arduino", "plot"


local function finite(text)
  local number = tonumber(text)
  -- (not inf or nan)
  if number and number == number and number ~= math.huge and number ~= -math.huge then return number end
end


---Reads the numbers of a line: every field must be a number, "label:number",
---or "label:" followed by a number (as `Serial.print("Temp: ")` prints), so
---text messages are not plotted.
---@param text string
---@return { name: string, value: number }[]? fields nil when the line is not a sample
function plot.parse(text)
  local fields = {}
  local position, label = 0, nil
  for field in text:gmatch("[^%s,]+") do
    position = position + 1
    local name, value = field:match("^(.*):([^:]*)$")
    if name and value == "" then
      -- "Temp:" then the number in the next field
      if label or name == "" then return nil end
      label = name
    else
      local number = finite(name and value or field)
      if not number then return nil end
      name = (name and name ~= "") and name or label or ("Value " .. position)
      table.insert(fields, { name = name, value = number })
      label = nil
    end
  end
  if label then return nil end
  return #fields > 0 and fields or nil
end


local function trim()
  local extra = plot.count - plot.first + 1 - plot.MAX_SAMPLES
  if extra <= 0 then return end
  for i = plot.first, plot.first + extra - 1 do
    for _, series in ipairs(plot.series) do series.values[i] = nil end
  end
  plot.first = plot.first + extra
end


---Adds a sample from a line, if it has numbers.
---@param text string
---@return boolean added
function plot.add_line(text)
  local fields = plot.parse(text)
  if not fields then return false end
  plot.count = plot.count + 1
  for _, field in ipairs(fields) do
    local series = by_name[field.name]
    if not series then
      series = { name = field.name, color = #plot.series + 1, values = {}, hidden = false }
      table.insert(plot.series, series)
      by_name[field.name] = series
    end
    series.values[plot.count] = field.value
    series.last = field.value
  end
  trim()
  core.redraw = true
  return true
end


---Removes all samples and series.
function plot.clear()
  plot.series, by_name = {}, {}
  plot.count, plot.first = 0, 1
  if plot.paused_at then plot.paused_at = 0 end
  core.redraw = true
end


---Freezes the view at the latest sample, or follows new samples again.
function plot.set_paused(paused)
  plot.paused_at = paused and plot.count or nil
  core.redraw = true
end


---The samples shown: the last `window` ones up to the latest (or the paused) sample.
---@return integer first
---@return integer last
function plot.range()
  local last = plot.paused_at or plot.count
  local first = math.max(plot.first, last - plot.window() + 1)
  return first, last
end


---The lowest and highest shown value of the shown series, if any.
function plot.bounds()
  local first, last = plot.range()
  local low, high
  for _, series in ipairs(plot.series) do
    if not series.hidden then
      for i = first, last do
        local v = series.values[i]
        if v then
          if not low or v < low then low = v end
          if not high or v > high then high = v end
        end
      end
    end
  end
  return low, high
end


function plot.window()
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  return type(saved) == "table" and tonumber(saved.window) or plot.DEFAULT_WINDOW
end


function plot.set_window(n)
  local saved = storage.load(STORAGE_MODULE, STORAGE_KEY)
  saved = type(saved) == "table" and saved or {}
  saved.window = n
  storage.save(STORAGE_MODULE, STORAGE_KEY, saved)
  core.redraw = true
end


table.insert(monitor.on_line, function(line) plot.add_line(line.text) end)


return plot
