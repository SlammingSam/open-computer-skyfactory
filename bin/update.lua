-- update.lua — pull changed files from GitHub, skipping everything that has
-- not changed.
--
--   update                  update lib/, bin/ and diag/
--   update --all            also install docs/
--   update --force          re-download everything, ignoring the saved state
--   update --list           show what would change, write nothing
--   update --prune          also delete local files that left the repo
--   update --quiet          print only changes and errors (for startup)
--   update --install-startup   run the updater automatically at boot
--
-- HOW IT AVOIDS OVERWRITING FILES IT DOES NOT NEED TO
--
-- GitHub's tree API returns a blob SHA for every file. Those SHAs are saved to
-- /home/.update_state after each run, so the next run compares SHAs from a
-- single API call and downloads only what actually changed. A file whose SHA
-- is unchanged is never fetched and never written, so its timestamp and
-- contents are left completely alone.
--
-- /home/.env is never written by this script. That is where the proxy address,
-- API keys and per-machine settings live, precisely so updates cannot clobber
-- them.

local component = require("component")
local fs        = require("filesystem")

-- ============================== module loading ==============================

local function scriptDir()
  local ok, info = pcall(function() return debug.getinfo(1, "S") end)
  if not ok or not info or type(info.source) ~= "string" then return nil end
  if info.source:sub(1, 1) ~= "@" then return nil end
  return info.source:sub(2):match("^(.*)/[^/]*$")
end

local function loadModule(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end

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
  add(name .. ".lua")

  for _, p in ipairs(candidates) do
    local chunk = loadfile(p)
    if chunk then
      local okc, m = pcall(chunk)
      if okc and type(m) == "table" then return m, p end
    end
  end
  return nil
end

local json = loadModule("json")
if not json then
  print("update.lua: could not find lib/json.lua.")
  print("Clone the repo and run this from inside it, or copy lib/*.lua to /home/lib/.")
  return
end

local env = loadModule("env")

-- ================================= config ===================================

local function cfg(key, default)
  if env then return env.get(key, default) end
  return default
end

local REPO   = cfg("UPDATE_REPO", "SlammingSam/open-computer-skyfactory")
local BRANCH = cfg("UPDATE_BRANCH", "main")
local TOKEN  = cfg("GITHUB_TOKEN")     -- optional; only raises the rate limit

local STATE_PATH = "/home/.update_state"

-- Which parts of the repo get installed, and where they land.
local INSTALL = {
  { prefix = "lib/",  dest = "/home/lib/" },
  { prefix = "bin/",  dest = "/home/bin/" },
  { prefix = "diag/", dest = "/home/diag/" },
}
local INSTALL_ALL = { { prefix = "docs/", dest = "/home/docs/" } }

-- Never written, whatever the repo says. Secrets and per-machine settings.
local PROTECTED = { ["/home/.env"] = true }

-- ================================ arguments =================================

local args = { ... }
local opt = {}
for _, a in ipairs(args) do
  opt[a:gsub("^%-%-", "")] = true
end

local function say(...)
  if not opt.quiet then print(...) end
end

-- ================================ fetching ==================================
-- The proxy computer has an Internet Card and cannot use http.lua (which needs
-- a proxy to talk to). Every other computer has only a modem. Support both, so
-- one updater works on the whole network.

local http = nil
local directInternet = component.isAvailable("internet") and component.internet or nil

if not directInternet then
  http = loadModule("http")
  if not http then
    print("update.lua: no Internet Card here, and lib/http.lua could not be loaded.")
    return
  end
  if type(http.setTimeout) == "function" then pcall(http.setTimeout, 60) end
end

local function fetchDirect(url, headers)
  local handle = directInternet.request(url, nil, headers)
  if not handle then return nil, "could not open " .. url end

  if type(handle.finishConnect) ~= "nil" then
    local deadline = os.clock() + 15
    while os.clock() < deadline do
      local ok, err = handle.finishConnect()
      if ok == true then break end
      if ok == nil then
        pcall(function() handle.close() end)
        return nil, tostring(err or "connection failed")
      end
      os.sleep(0.05)
    end
  end

  local chunks, total, emptyUntil = {}, 0, nil
  local deadline = os.clock() + 30
  while os.clock() < deadline do
    local ok, chunk = pcall(function() return handle.read(8192) end)
    if not ok then break end
    if chunk == nil then break end
    if chunk == "" then
      emptyUntil = emptyUntil or (os.clock() + (total > 0 and 2 or 15))
      if os.clock() > emptyUntil then break end
      os.sleep(0.05)
    else
      chunks[#chunks + 1] = chunk
      total = total + #chunk
      emptyUntil = nil
      os.sleep(0)
    end
  end
  pcall(function() handle.close() end)

  local body = table.concat(chunks)
  if body == "" then return nil, "empty response from " .. url end
  return body
end

local function fetch(url)
  local headers = { ["User-Agent"] = "OpenComputers-update" }
  if TOKEN then headers["Authorization"] = "token " .. TOKEN end

  if directInternet then return fetchDirect(url, headers) end

  local body, err = http.get(url, headers)
  if not body then return nil, err end
  if body == "" then return nil, "empty response from " .. url end
  return body
end

-- ================================== state ===================================

local serialization = require("serialization")

local function loadState()
  local f = io.open(STATE_PATH, "r")
  if not f then return { files = {} } end
  local raw = f:read("*a"); f:close()
  local ok, value = pcall(serialization.unserialize, raw)
  if ok and type(value) == "table" and type(value.files) == "table" then return value end
  return { files = {} }
end

-- Written the same way factory.lua writes its settings: to a temp file that is
-- read back before it replaces the live one, so a crash mid-write cannot leave
-- a corrupt state file that makes the next run re-download everything.
local function saveState(state)
  local ok, data = pcall(serialization.serialize, state)
  if not ok then return false end
  local tmp = STATE_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(data); f:close()

  local check = io.open(tmp, "r")
  if not check then return false end
  local back = check:read("*a"); check:close()
  if not back or back == "" then return false end

  pcall(fs.remove, STATE_PATH)
  local moved = pcall(fs.rename, tmp, STATE_PATH)
  if not moved then
    local d = io.open(STATE_PATH, "w")
    if not d then return false end
    d:write(data); d:close()
  end
  return true
end

-- ================================== repo ====================================

local function installPathFor(repoPath)
  local maps = INSTALL
  if opt.all then
    maps = {}
    for _, m in ipairs(INSTALL) do maps[#maps + 1] = m end
    for _, m in ipairs(INSTALL_ALL) do maps[#maps + 1] = m end
  end
  for _, m in ipairs(maps) do
    if repoPath:sub(1, #m.prefix) == m.prefix then
      return m.dest .. repoPath:sub(#m.prefix + 1)
    end
  end
  return nil
end

local function fetchTree()
  local url = "https://api.github.com/repos/" .. REPO ..
              "/git/trees/" .. BRANCH .. "?recursive=1"
  local body, err = fetch(url)
  if not body then return nil, err end

  local data = json.decode(body)
  if type(data) ~= "table" then
    return nil, "could not parse the repo listing: " .. tostring(body):sub(1, 120)
  end
  if data.message then
    return nil, "GitHub: " .. tostring(data.message)
  end
  if type(data.tree) ~= "table" then
    return nil, "the repo listing had no file tree in it"
  end

  local files = {}
  for _, entry in ipairs(data.tree) do
    if type(entry) == "table" and entry.type == "blob" and entry.path then
      files[#files + 1] = { path = entry.path, sha = entry.sha, size = entry.size }
    end
  end
  return files
end

local function writeFile(dest, content)
  local dir = dest:match("^(.*)/[^/]*$")
  if dir and dir ~= "" and not fs.exists(dir) then
    local ok, err = pcall(fs.makeDirectory, dir)
    if not ok then return false, "could not create " .. dir .. ": " .. tostring(err) end
  end
  local f, err = io.open(dest, "w")
  if not f then return false, tostring(err) end
  f:write(content)
  f:close()
  return true
end

-- ================================== main ====================================

local function run()
  say("[update] " .. REPO .. " @ " .. BRANCH ..
      (directInternet and "  (direct)" or "  (via proxy)"))

  local files, err = fetchTree()
  if not files then
    print("[update] could not read the repo: " .. tostring(err))
    return false
  end

  local state = loadState()
  local updated, unchanged, failed, skipped = 0, 0, 0, 0
  local seen = {}

  for _, entry in ipairs(files) do
    local dest = installPathFor(entry.path)

    if not dest then
      skipped = skipped + 1
    elseif PROTECTED[dest] then
      say("[update]   protected " .. dest .. " - left alone")
      skipped = skipped + 1
    else
      seen[entry.path] = dest
      local prev = state.files[entry.path]
      local exists = fs.exists(dest)
      local needed = opt.force or not exists or not prev or prev.sha ~= entry.sha

      if not needed then
        unchanged = unchanged + 1
      elseif opt.list then
        say("[update]   would update " .. entry.path)
        updated = updated + 1
      else
        local url = "https://raw.githubusercontent.com/" .. REPO .. "/" ..
                    BRANCH .. "/" .. entry.path
        local content, ferr = fetch(url)

        if not content then
          print("[update]   FAILED " .. entry.path .. ": " .. tostring(ferr))
          failed = failed + 1
        elseif entry.size and #content ~= entry.size then
          -- Short read: leave the old file in place and do not record the SHA,
          -- so the next run tries again rather than treating it as done.
          print(string.format("[update]   FAILED %s: got %d bytes, expected %d",
                              entry.path, #content, entry.size))
          failed = failed + 1
        else
          local ok, werr = writeFile(dest, content)
          if ok then
            say("[update]   " .. (exists and "updated" or "new    ") .. "  " .. entry.path)
            state.files[entry.path] = { sha = entry.sha, size = entry.size, dest = dest }
            updated = updated + 1
          else
            print("[update]   FAILED " .. entry.path .. ": " .. tostring(werr))
            failed = failed + 1
          end
        end
        os.sleep(0)
      end
    end
  end

  -- Files that left the repo. Reported always, removed only on request, since
  -- deleting something the user still wants is worse than a stale file.
  local gone = {}
  for path, info in pairs(state.files) do
    if not seen[path] then gone[#gone + 1] = { path = path, dest = info.dest } end
  end
  if #gone > 0 then
    for _, g in ipairs(gone) do
      if opt.prune and g.dest and not PROTECTED[g.dest] then
        pcall(fs.remove, g.dest)
        say("[update]   removed  " .. g.path)
        state.files[g.path] = nil
      else
        say("[update]   gone from the repo: " .. g.path ..
            (opt.prune and "" or "  (run --prune to delete)"))
      end
    end
  end

  if not opt.list then saveState(state) end

  local summary = string.format("[update] %d updated, %d unchanged, %d failed",
                                updated, unchanged, failed)
  if opt.quiet then
    -- At boot, silence is the good outcome; only speak when something happened.
    if updated > 0 or failed > 0 then print(summary) end
  else
    print(summary .. string.format(" (%d not installed by this script)", skipped))
  end

  -- Programs land in /home/bin, which is only runnable by name if the shell
  -- looks there. Worth saying once rather than leaving "ollama: not found" to
  -- be puzzled over.
  local path = os.getenv("PATH") or ""
  if not path:find("/home/bin", 1, true) then
    print("[update] NOTE: /home/bin is not on PATH, so installed programs will")
    print("         not run by name. Add this line to /home/.shrc:")
    print('           export PATH=$PATH:/home/bin')
    print("         Until then, run them with their full path: /home/bin/ollama.lua")
  end

  return failed == 0
end

-- ============================ startup installation ==========================
-- OpenOS runs /home/.shrc when the shell starts, which on a computer that
-- boots straight to a prompt is effectively startup.

local SHRC = "/home/.shrc"
local STARTUP_LINE = "/home/bin/update.lua --quiet"

local function installStartup()
  local existing = ""
  local f = io.open(SHRC, "r")
  if f then existing = f:read("*a") or ""; f:close() end

  if existing:find("update.lua", 1, true) then
    print("[update] " .. SHRC .. " already runs the updater at startup.")
    return
  end

  local out = io.open(SHRC, "a")
  if not out then
    print("[update] could not write " .. SHRC)
    return
  end
  if existing ~= "" and not existing:match("\n$") then out:write("\n") end
  out:write("# Pull changed files from GitHub at startup. Remove this line to stop.\n")
  out:write(STARTUP_LINE .. "\n")
  out:close()

  print("[update] added to " .. SHRC .. ":")
  print("           " .. STARTUP_LINE)
  print("[update] It runs on the next reboot, and prints only when something changed.")
end

-- =================================== cli ====================================

if opt["install-startup"] then
  installStartup()
  return
end

if opt.help or opt.h then
  print("update [--all] [--force] [--list] [--prune] [--quiet] [--install-startup]")
  print("  no flags          update lib/, bin/ and diag/, skipping unchanged files")
  print("  --all             also install docs/")
  print("  --force           re-download everything")
  print("  --list            show what would change, write nothing")
  print("  --prune           delete local files that left the repo")
  print("  --quiet           print only changes and errors")
  print("  --install-startup run the updater automatically at boot")
  print("")
  print("Settings come from /home/.env: UPDATE_REPO, UPDATE_BRANCH, GITHUB_TOKEN.")
  print("/home/.env itself is never overwritten.")
  return
end

local ok, err = pcall(run)
if not ok then
  print("[update] crashed: " .. tostring(err))
end
