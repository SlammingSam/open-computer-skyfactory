-- env.lua — reads /home/.env so secrets and machine-specific settings live in
-- one file that updates never touch.
--
-- Format is the usual KEY=VALUE, one per line. Blank lines and lines starting
-- with # are ignored, a leading "export " is allowed, and surrounding single
-- or double quotes are stripped.
--
--   local env = require("env")          -- or see loadModule() in bin/*.lua
--   local addr = env.get("PROXY_ADDRESS")
--   local host = env.get("OLLAMA_HOST", "http://127.0.0.1:11434")
--
-- Nothing here ever prints a value. A misconfigured key should produce a
-- message naming the KEY, never its contents — this file holds API keys.

local env = {}

local DEFAULT_PATH = "/home/.env"

local cache, cachePath = nil, nil

local function parse(path)
  local values = {}
  local f = io.open(path, "r")
  if not f then return nil, "could not open " .. path end

  for rawLine in f:lines() do
    local line = rawLine:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^export%s+", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local key, value = line:match("^([%w_%.]+)%s*=%s*(.*)$")
      if key then
        -- Strip matching quotes, then a trailing comment on unquoted values.
        local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
        if unquoted then
          value = unquoted
        else
          value = value:gsub("%s+#.*$", ""):gsub("%s+$", "")
        end
        values[key] = value
      end
    end
  end

  f:close()
  return values
end

-- Loads (and caches) the file. Returns the table of values; an absent file is
-- not an error, it just means nothing is configured yet.
function env.load(path)
  path = path or DEFAULT_PATH
  if cache and cachePath == path then return cache end
  local values, err = parse(path)
  cache, cachePath = values or {}, path
  return cache, err
end

function env.reload(path)
  cache, cachePath = nil, nil
  return env.load(path)
end

-- Returns the value for `key`, or `default` when it is missing or blank.
function env.get(key, default, path)
  local values = env.load(path)
  local value = values[key]
  if value == nil or value == "" then return default end
  return value
end

-- Same, but as a number.
function env.number(key, default, path)
  return tonumber(env.get(key, nil, path)) or default
end

-- Same, but as a boolean: true/yes/on/1 are true, anything else present is
-- false.
function env.bool(key, default, path)
  local value = env.get(key, nil, path)
  if value == nil then return default end
  value = value:lower()
  return value == "true" or value == "yes" or value == "on" or value == "1"
end

function env.path() return cachePath or DEFAULT_PATH end
function env.defaultPath() return DEFAULT_PATH end

-- Which of the given keys are present, for a startup summary. Returns only
-- names, never values.
function env.present(keys, path)
  local values = env.load(path)
  local have, missing = {}, {}
  for _, key in ipairs(keys) do
    if values[key] and values[key] ~= "" then
      have[#have + 1] = key
    else
      missing[#missing + 1] = key
    end
  end
  return have, missing
end

-- Writes or replaces a single key, preserving every other line, comments
-- included. Used by the updater to remember a discovered proxy address.
function env.set(key, value, path)
  path = path or DEFAULT_PATH
  local lines, found = {}, false

  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local existing = line:gsub("^%s+", ""):gsub("^export%s+", ""):match("^([%w_%.]+)%s*=")
      if existing == key then
        lines[#lines + 1] = key .. "=" .. tostring(value)
        found = true
      else
        lines[#lines + 1] = line
      end
    end
    f:close()
  end

  if not found then lines[#lines + 1] = key .. "=" .. tostring(value) end

  local out, err = io.open(path, "w")
  if not out then return false, "could not write " .. path .. ": " .. tostring(err) end
  out:write(table.concat(lines, "\n") .. "\n")
  out:close()

  cache, cachePath = nil, nil -- force a reread
  return true
end

return env
