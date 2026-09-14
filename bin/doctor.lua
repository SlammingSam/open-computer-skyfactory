-- doctor.lua — check this machine's setup and say what is wrong.
--
--   doctor          run every check that applies to this computer
--   doctor --quiet  print only problems
--
-- Every failure this project has hit in practice is checked here: an old
-- http.lua that cannot chunk, a proxy that cannot be found, loopback blocked
-- by the mod, a model with no tool support, /home/bin missing from PATH. Each
-- one cost a debugging session to identify; none of them should cost a second.
--
-- Reports only. It changes nothing.

local component = require("component")

local function scriptDir()
  local ok, info = pcall(function() return debug.getinfo(1, "S") end)
  if not ok or not info or type(info.source) ~= "string" then return nil end
  if info.source:sub(1, 1) ~= "@" then return nil end
  return info.source:sub(2):match("^(.*)/[^/]*$")
end

local function loadModule(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod, "require(" .. name .. ")" end
  local candidates, seen = {}, {}
  local function add(p)
    if p and not seen[p] then seen[p] = true; candidates[#candidates + 1] = p end
  end
  local dir = scriptDir()
  if dir then
    add(dir .. "/../lib/" .. name .. ".lua")
    add(dir .. "/" .. name .. ".lua")
  end
  add("/home/lib/" .. name .. ".lua")
  add("/usr/lib/" .. name .. ".lua")
  add("/lib/" .. name .. ".lua")
  add("lib/" .. name .. ".lua")
  for _, p in ipairs(candidates) do
    local chunk = loadfile(p)
    if chunk then
      local okc, m = pcall(chunk)
      if okc and type(m) == "table" then return m, p end
    end
  end
  return nil
end

-- ================================= output ===================================

local args = { ... }
local quiet = false
for _, a in ipairs(args) do
  if a == "--quiet" or a == "-q" then quiet = true end
end

local counts = { ok = 0, warn = 0, bad = 0 }

local function report(level, what, detail, fix)
  counts[level] = counts[level] + 1
  if quiet and level == "ok" then return end
  local mark = (level == "ok" and "  OK  ") or (level == "warn" and " WARN ") or (" FAIL ")
  print(mark .. what .. (detail and ("  " .. detail) or ""))
  if fix and level ~= "ok" then print("       -> " .. fix) end
end

local function section(title)
  if not quiet then print(""); print("== " .. title .. " ==") end
end

-- ================================ hardware ==================================

section("hardware")

local present = {}
pcall(function()
  for _, ctype in component.list() do present[ctype] = (present[ctype] or 0) + 1 end
end)

local names = {}
for ctype, n in pairs(present) do
  names[#names + 1] = (n > 1) and (ctype .. " x" .. n) or ctype
end
table.sort(names)
report("ok", "components", table.concat(names, ", "))

local isProxy = present.internet ~= nil

if present.modem then
  report("ok", "network card", "present")
else
  report("bad", "network card", "missing",
         "Without a modem this computer cannot reach the proxy, and nothing here works.")
end

if isProxy then
  report("ok", "internet card", "present — this is the proxy machine")
end

-- ================================ libraries =================================

section("libraries")

local env,  envPath  = loadModule("env")
local json, jsonPath = loadModule("json")
local http, httpPath = loadModule("http")

if env then report("ok", "lib/env", "from " .. envPath)
else report("warn", "lib/env", "not found",
            "Settings fall back to compiled-in defaults. Run: update") end

if json then report("ok", "lib/json", "from " .. jsonPath)
else report("bad", "lib/json", "not found",
            "ollama.lua and update.lua both need it. Run: update") end

if not http then
  report("bad", "lib/http", "not found",
         "Copy lib/http.lua to /home/lib/, or run: update")
else
  report("ok", "lib/http", "from " .. httpPath)
  if http.chunked then
    report("ok", "http chunking", "supported")
  else
    report("bad", "http chunking", "NOT supported — this is an old http.lua",
           "Replies over ~4 KB will be dropped by the modem and look like a " ..
           "timeout. Run: update   (and update bin/proxy.lua on the proxy too)")
  end
  if type(http.setTimeout) ~= "function" then
    report("warn", "http.setTimeout", "missing",
           "Local model inference will hit the default timeout. Run: update")
  end
end

-- ============================== configuration ===============================

section("configuration")

local KNOWN = { "PROXY_ADDRESS", "OLLAMA_HOST", "OLLAMA_MODEL", "HTTP_TIMEOUT",
                "UPDATE_REPO", "UPDATE_BRANCH", "GITHUB_TOKEN", "ANTHROPIC_API_KEY" }

if not env then
  report("warn", "/home/.env", "cannot be read without lib/env")
else
  local probe = io.open(env.defaultPath(), "r")
  if probe then
    probe:close()
    -- Names only. This file holds API keys; it is never printed.
    local have = env.present(KNOWN)
    report("ok", "/home/.env", (#have > 0)
      and ("set: " .. table.concat(have, ", "))
      or "present but nothing recognised is set")
  else
    report("warn", "/home/.env", "not present",
           "Copy .env.example to /home/.env. Without it every setting falls " ..
           "back to a default, and a discovered proxy address is not remembered.")
  end
end

local path = os.getenv("PATH") or ""
if path:find("/home/bin", 1, true) then
  report("ok", "PATH", "includes /home/bin")
else
  report("warn", "PATH", "does not include /home/bin",
         "Installed programs will not run by name. Add to /home/.shrc:  " ..
         "export PATH=$PATH:/home/bin")
end

local stateFile = io.open("/home/.update_state", "r")
if stateFile then
  stateFile:close()
  report("ok", "updater", "has run here before")
else
  report("warn", "updater", "no record of a run",
         "Run: update   (it will install lib/, bin/ and diag/)")
end

-- ================================ the proxy =================================

section("network")

if isProxy then
  report("ok", "proxy", "this machine IS the proxy; start it with: proxy")
elseif not http then
  report("bad", "proxy", "cannot check without lib/http")
else
  local addr = http.proxyAddress()
  if addr then
    report("ok", "proxy", "found at " .. addr)
  else
    report("bad", "proxy", "not found",
           "Start proxy.lua on the machine with the Internet Card, or set " ..
           "PROXY_ADDRESS in /home/.env to the address it prints.")
  end
end

-- ================================== ollama ==================================

section("ollama")

local host = (env and env.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
             or "http://127.0.0.1:11434"
local wantModel = (env and env.get("OLLAMA_MODEL", "qwen2.5:7b-instruct"))
                  or "qwen2.5:7b-instruct"

if not http or not json then
  report("warn", "ollama", "cannot check without lib/http and lib/json")
elseif isProxy then
  report("ok", "ollama", "skipped — run doctor on the client, which is what talks to it")
else
  local body, err = http.get(host .. "/api/tags")

  if not body then
    report("bad", "ollama", "unreachable at " .. host, tostring(err))
  elseif body == "" then
    report("bad", "ollama", "empty reply from " .. host,
           "OpenComputers blocks loopback and private addresses by default. " ..
           "Remove 127.0.0.0/8 from blacklist in the internet section of " ..
           "opencomputers.cfg and restart the server. Run nettest on the " ..
           "proxy machine to confirm.")
  else
    local data = json.decode(body)
    if type(data) ~= "table" or type(data.models) ~= "table" then
      report("bad", "ollama", "unexpected reply", body:sub(1, 80))
    else
      report("ok", "ollama", "reachable at " .. host)

      local found, tools = false, nil
      local capable = {}
      for _, m in ipairs(data.models) do
        local caps = {}
        for _, c in ipairs(m.capabilities or {}) do caps[tostring(c)] = true end
        if caps.tools then capable[#capable + 1] = m.name end
        if m.name == wantModel or (m.name:gsub(":latest$", "") == wantModel) then
          found = true
          if m.capabilities then tools = caps.tools == true end
        end
      end

      if not found then
        report("bad", "model", wantModel .. " is not installed",
               "On the Ollama machine run:  ollama pull " .. wantModel)
      elseif tools == false then
        report("bad", "model", wantModel .. " cannot call tools",
               "It will write out its tool calls as text and nothing will run. " ..
               "Models here that can: " ..
               ((#capable > 0) and table.concat(capable, ", ") or "none installed"))
      elseif tools == nil then
        report("warn", "model", wantModel .. " installed; this Ollama does not " ..
               "report capabilities, so tool support is unknown")
      else
        report("ok", "model", wantModel .. " installed, and can call tools")
      end
    end
  end
end

-- ================================= verdict ==================================

print("")
if counts.bad > 0 then
  print(string.format("%d problem%s to fix, %d warning%s.",
        counts.bad, counts.bad == 1 and "" or "s",
        counts.warn, counts.warn == 1 and "" or "s"))
elseif counts.warn > 0 then
  print(string.format("Nothing broken, %d thing%s worth tidying.",
        counts.warn, counts.warn == 1 and "" or "s"))
else
  print("Everything checks out.")
end
