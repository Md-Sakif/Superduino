-- Reading and editing the build profiles of a sketch project file (sketch.yaml).
-- arduino-cli can add profiles but not change them, so changes are made here,
-- line by line: only the lines that change are touched, so libraries, other
-- profiles, comments and formatting are kept.
local sketch_yaml = {}

---@class arduino.sketch_profile
---@field name string
---@field fqbn? string
---@field header_line integer Line of "  name:"
---@field last_line integer Last line of the profile (without trailing blank lines)
---@field fqbn_line? integer
---@field platforms_line? integer Line of "platforms:"
---@field platforms_last? integer Last line of the platforms list

---@class arduino.sketch_file
---@field lines string[]
---@field newline string
---@field profiles arduino.sketch_profile[]
---@field default_name? string
---@field default_line? integer


local function unquote(value)
  value = value:gsub("%s+#.*$", ""):gsub("%s+$", "")
  return value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
end

local function indent_of(line) return #line:match("^ *") end
local function is_blank(line) return line:match("^%s*$") ~= nil or line:match("^%s*#") ~= nil end


---@param text string
---@return arduino.sketch_file
function sketch_yaml.parse(text)
  local file = { lines = {}, newline = text:find("\r\n", 1, true) and "\r\n" or "\n", profiles = {} }
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(file.lines, (line:gsub("\r$", "")))
  end
  -- the split above adds an empty last line for text ending in a newline
  if file.lines[#file.lines] == "" then table.remove(file.lines) end

  local in_profiles, profile_indent, current = false, nil, nil
  local function close(last)
    if not current then return end
    while last > current.header_line and is_blank(file.lines[last]) do last = last - 1 end
    current.last_line = last
    if current.platforms_line then
      -- the list runs until the next key of the profile
      local j = current.platforms_line
      local key_indent = indent_of(file.lines[j])
      while j + 1 <= last do
        local line = file.lines[j + 1]
        local ind = indent_of(line)
        if not is_blank(line) and ind <= key_indent and not (ind == key_indent and line:match("^%s*%- ")) then break end
        j = j + 1
      end
      while j > current.platforms_line and is_blank(file.lines[j]) do j = j - 1 end
      current.platforms_last = j
    end
    current = nil
  end

  for i, line in ipairs(file.lines) do
    if line:match("^[^%s#]") then
      close(i - 1)
      in_profiles = line:match("^profiles:%s*$") ~= nil
      local default = line:match("^default_profile:%s*(.-)%s*$")
      if default then file.default_name, file.default_line = unquote(default), i end
    elseif in_profiles and not is_blank(line) then
      local ind = indent_of(line)
      profile_indent = profile_indent or ind
      local name = ind == profile_indent and line:match("^%s*([^%s:#][^:#]-):%s*$")
      if name then
        close(i - 1)
        current = { name = unquote(name), header_line = i }
        table.insert(file.profiles, current)
      elseif current and ind > profile_indent then
        local fqbn = line:match("^%s*fqbn:%s*(.-)%s*$")
        if fqbn and not current.fqbn_line then
          current.fqbn, current.fqbn_line = unquote(fqbn), i
        elseif line:match("^%s*platforms:%s*$") and not current.platforms_line then
          current.platforms_line = i
        end
      end
    end
  end
  close(#file.lines)
  return file
end


---@param file arduino.sketch_file
---@param name string
---@return arduino.sketch_profile?
function sketch_yaml.profile(file, name)
  for _, profile in ipairs(file.profiles) do
    if profile.name == name then return profile end
  end
end


---The profile used when none is chosen: the default one, else the first.
---@param file arduino.sketch_file
---@return arduino.sketch_profile?
function sketch_yaml.default_profile(file)
  return (file.default_name and sketch_yaml.profile(file, file.default_name)) or file.profiles[1]
end


---Lines of a profile's platforms list ("platforms:" and its entries).
---@param file arduino.sketch_file
---@param profile arduino.sketch_profile
---@return string[]?
function sketch_yaml.platform_lines(file, profile)
  if not profile.platforms_line then return nil end
  local lines = {}
  for i = profile.platforms_line, profile.platforms_last do table.insert(lines, file.lines[i]) end
  return lines
end


---Changes a profile and returns the new text of the file.
---@param file arduino.sketch_file
---@param name string Profile to change
---@param change { fqbn?: string, platform_lines?: string[], rename?: string }
---`platform_lines` replaces the platforms list, re-indented to fit.
---@return string
function sketch_yaml.update(file, name, change)
  local profile = assert(sketch_yaml.profile(file, name), "no profile " .. name)
  local lines = {}
  for i, line in ipairs(file.lines) do lines[i] = line end
  local child_indent = string.rep(" ", indent_of(lines[profile.header_line]) + 2)
  if profile.fqbn_line then
    child_indent = lines[profile.fqbn_line]:match("^ *")
  elseif profile.platforms_line then
    child_indent = lines[profile.platforms_line]:match("^ *")
  end

  -- replaced from the bottom up, so earlier line numbers stay valid
  local edits = {}
  if change.platform_lines then
    local base = indent_of(change.platform_lines[1])
    local new = {}
    for _, line in ipairs(change.platform_lines) do
      local extra = math.max(0, indent_of(line) - base)
      table.insert(new, child_indent .. string.rep(" ", extra) .. line:gsub("^ *", ""))
    end
    if profile.platforms_line then
      table.insert(edits, { first = profile.platforms_line, last = profile.platforms_last, lines = new })
    else
      local after = profile.fqbn_line or profile.header_line
      table.insert(edits, { first = after + 1, last = after, lines = new })
    end
  end
  if change.fqbn then
    if profile.fqbn_line then
      local prefix = lines[profile.fqbn_line]:match("^(%s*fqbn:%s*)")
      table.insert(edits, { first = profile.fqbn_line, last = profile.fqbn_line, lines = { prefix .. change.fqbn } })
    else
      table.insert(edits, { first = profile.header_line + 1, last = profile.header_line,
        lines = { child_indent .. "fqbn: " .. change.fqbn } })
    end
  end
  if change.rename then
    local header = lines[profile.header_line]:match("^%s*") .. change.rename .. ":"
    table.insert(edits, { first = profile.header_line, last = profile.header_line, lines = { header } })
    if file.default_line and file.default_name == name then
      table.insert(edits, { first = file.default_line, last = file.default_line,
        lines = { "default_profile: " .. change.rename } })
    end
  end
  -- inserts at the same line: the later one in `edits` is applied last, so it ends up first
  for i, edit in ipairs(edits) do edit.order = i end
  table.sort(edits, function(a, b)
    if a.first ~= b.first then return a.first > b.first end
    return a.order < b.order
  end)
  for _, edit in ipairs(edits) do
    for _ = edit.first, edit.last do table.remove(lines, edit.first) end
    for k = #edit.lines, 1, -1 do table.insert(lines, edit.first, edit.lines[k]) end
  end
  return table.concat(lines, file.newline) .. file.newline
end


return sketch_yaml
