-- Minimal JSON decoder for arduino-cli output.
local json = {}

local escapes = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local decode_value

local function decode_error(str, pos, message)
  error(string.format("invalid JSON at position %d: %s", pos, message), 0)
end

local function skip_whitespace(str, pos)
  return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function decode_string(str, pos)
  local parts = {}
  local i = pos + 1
  while true do
    local j = str:find('["\\]', i)
    if not j then decode_error(str, pos, "unterminated string") end
    table.insert(parts, str:sub(i, j - 1))
    if str:sub(j, j) == '"' then
      return table.concat(parts), j + 1
    end
    local esc = str:sub(j + 1, j + 1)
    if esc == "u" then
      local code = tonumber(str:sub(j + 2, j + 5), 16)
      if not code then decode_error(str, j, "invalid unicode escape") end
      i = j + 6
      -- combine UTF-16 surrogate pairs
      if code >= 0xD800 and code <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
        local low = tonumber(str:sub(i + 2, i + 5), 16)
        if low and low >= 0xDC00 and low <= 0xDFFF then
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          i = i + 6
        end
      end
      table.insert(parts, utf8.char(code))
    elseif escapes[esc] then
      table.insert(parts, escapes[esc])
      i = j + 2
    else
      decode_error(str, j, "invalid escape")
    end
  end
end

local function decode_array(str, pos)
  local result, n = {}, 0
  pos = skip_whitespace(str, pos + 1)
  if str:sub(pos, pos) == "]" then return result, pos + 1 end
  while true do
    local value
    value, pos = decode_value(str, pos)
    n = n + 1
    result[n] = value
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "]" then return result, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or ']'") end
    pos = skip_whitespace(str, pos + 1)
  end
end

local function decode_object(str, pos)
  local result = {}
  pos = skip_whitespace(str, pos + 1)
  if str:sub(pos, pos) == "}" then return result, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected string key") end
    local key
    key, pos = decode_string(str, pos)
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
    local value
    value, pos = decode_value(str, skip_whitespace(str, pos + 1))
    result[key] = value
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "}" then return result, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or '}'") end
    pos = skip_whitespace(str, pos + 1)
  end
end

decode_value = function(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return decode_object(str, pos) end
  if c == "[" then return decode_array(str, pos) end
  if c == '"' then return decode_string(str, pos) end
  if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
  local number = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  if number and number ~= "" and tonumber(number) then
    return tonumber(number), pos + #number
  end
  decode_error(str, pos, "unexpected character")
end

---Decodes a JSON document. `null` becomes nil.
---@param str string
---@return any value
---@return string? error
function json.decode(str)
  local ok, value, pos = pcall(decode_value, str, skip_whitespace(str, 1))
  if not ok then return nil, value end
  if skip_whitespace(str, pos) <= #str then
    return nil, string.format("invalid JSON at position %d: trailing data", pos)
  end
  return value
end

return json
