-- json.lua - minimal JSON encoder/decoder for OpenComputers.
--
-- Stock OpenComputers has no JSON library, and both the Ollama client and
-- the updater need real nested JSON (objects and arrays of arbitrary shape).
--
--   local json = require("json")   -- or see loadModule() in bin/*.lua
--   local t = json.decode('{"a":[1,2]}')
--   local s = json.encode({ a = 1 })
--
-- json.object(t) marks a table so it encodes as {} rather than [] when
-- empty, which matters for API payloads where the two are not
-- interchangeable. Decoded objects carry that marker automatically, so a
-- decode/encode round trip preserves an empty object.
--
-- Limitation: unicode escapes above 127 decode to a question mark (no
-- UTF-16 surrogate pair handling).

-- Stock OpenComputers has no JSON library, and tool calling needs real
-- nested JSON (objects/arrays of arbitrary shape), so this is a small
-- general-purpose encoder/decoder rather than the old field-by-field
-- string scanning. Limitations: \u escapes above 127 decode to "?"
-- (no UTF-16 surrogate pair handling) - fine for our purposes.
local json = {}

local emptyObjectMeta = {} -- marks a table as "always encode as {}"
function json.object(t)
  return setmetatable(t or {}, emptyObjectMeta)
end

local escapeMap = {
  ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n',
  ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}
local function jsonEscape(s)
  return (s:gsub('[%c\\"]', function(c)
    return escapeMap[c] or string.format('\\u%04x', c:byte())
  end))
end

local function isJsonArray(t)
  if getmetatable(t) == emptyObjectMeta then return false, 0 end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false, 0 end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false, 0 end
  end
  return true, n
end

function json.encode(v)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(v)
  elseif t == "string" then
    return '"' .. jsonEscape(v) .. '"'
  elseif t == "table" then
    local isArr, n = isJsonArray(v)
    if isArr then
      if n == 0 then return "[]" end
      local parts = {}
      for i = 1, n do parts[i] = json.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. json.encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    error("json.encode: cannot encode a " .. t)
  end
end

local decodeValue, decodeObject, decodeArray, decodeString

local function skipWs(s, i)
  local _, e = s:find("^%s*", i)
  return e + 1
end

decodeString = function(s, i)
  i = i + 1 -- skip opening quote
  local startI = i
  local buf = {}
  while true do
    local c = s:sub(i, i)
    if c == "" then error("unterminated string at " .. i) end
    if c == '"' then
      buf[#buf + 1] = s:sub(startI, i - 1)
      return table.concat(buf), i + 1
    elseif c == "\\" then
      buf[#buf + 1] = s:sub(startI, i - 1)
      local esc = s:sub(i + 1, i + 1)
      if esc == "n" then buf[#buf + 1] = "\n"; i = i + 2
      elseif esc == "t" then buf[#buf + 1] = "\t"; i = i + 2
      elseif esc == "r" then buf[#buf + 1] = "\r"; i = i + 2
      elseif esc == "b" then buf[#buf + 1] = "\b"; i = i + 2
      elseif esc == "f" then buf[#buf + 1] = "\f"; i = i + 2
      elseif esc == '"' then buf[#buf + 1] = '"'; i = i + 2
      elseif esc == "\\" then buf[#buf + 1] = "\\"; i = i + 2
      elseif esc == "/" then buf[#buf + 1] = "/"; i = i + 2
      elseif esc == "u" then
        local code = tonumber(s:sub(i + 2, i + 5), 16) or 63
        buf[#buf + 1] = (code < 128) and string.char(code) or "?"
        i = i + 6
      else
        buf[#buf + 1] = esc; i = i + 2
      end
      startI = i
    else
      i = i + 1
    end
  end
end

local function decodeNumber(s, i)
  local j, n = i, #s
  if s:sub(j, j) == "-" then j = j + 1 end
  while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
  if s:sub(j, j) == "." then
    j = j + 1
    while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
  end
  if s:sub(j, j) == "e" or s:sub(j, j) == "E" then
    j = j + 1
    if s:sub(j, j) == "+" or s:sub(j, j) == "-" then j = j + 1 end
    while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
  end
  return tonumber(s:sub(i, j - 1)), j
end

decodeObject = function(s, i)
  i = i + 1 -- skip '{'
  local obj = json.object({})
  i = skipWs(s, i)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    i = skipWs(s, i)
    local key
    key, i = decodeString(s, i)
    i = skipWs(s, i)
    if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
    i = skipWs(s, i + 1)
    local val
    val, i = decodeValue(s, i)
    obj[key] = val
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return obj, i + 1
    else
      error("expected ',' or '}' at " .. i)
    end
  end
end

decodeArray = function(s, i)
  i = i + 1 -- skip '['
  local arr, n = {}, 0
  i = skipWs(s, i)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    i = skipWs(s, i)
    local val
    val, i = decodeValue(s, i)
    n = n + 1
    arr[n] = val
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "]" then
      return arr, i + 1
    else
      error("expected ',' or ']' at " .. i)
    end
  end
end

decodeValue = function(s, i)
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == '"' then return decodeString(s, i)
  elseif c == "{" then return decodeObject(s, i)
  elseif c == "[" then return decodeArray(s, i)
  elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4
  elseif c == "-" or c:match("%d") then return decodeNumber(s, i)
  else error("unexpected character '" .. c .. "' at " .. i) end
end

function json.decode(s)
  local ok, val = pcall(function()
    local v = decodeValue(s, 1)
    return v
  end)
  if not ok then return nil, tostring(val) end
  return val
end

return json
