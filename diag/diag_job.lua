-- diag_job.lua — probe what an AE2 crafting job exposes on this bridge.
--
-- factory.lua can currently see only isDone() and isCanceled(), so when AE2
-- cancels a job it has to guess at the reason ("try a smaller max batch")
-- when the real cause might be an ingredient it can't source. This finds out
-- whether the handle carries anything better.
--
-- PART 1 is completely read-only: it dumps getCpus() in full, because the CPU
-- objects may describe the job they are running.
--
-- PART 2 cannot be read-only — a job handle only exists once a craft has been
-- requested — so it is OFF by default. Set PROBE_ITEM to the label of
-- something you are happy to have ONE of crafted, run it again, and it will
-- dump everything the returned handle exposes and then try to cancel it.

local component = require("component")

-- ============================== configuration ===============================

local PROBE_ITEM = nil    -- e.g. "Block of Quartz". nil = skip part 2 entirely.
local PROBE_QTY  = 1      -- kept at 1: this is a probe, not a production run.
local MAX_DEPTH  = 3

-- ================================= helpers ==================================

local function findAddr(ctype)
  for addr in component.list(ctype, true) do return addr end
end

local function safeCall(addr, method, ...)
  if not addr then return nil, "no component address" end
  local ok, a, b = pcall(component.invoke, addr, method, ...)
  if not ok then return nil, a end
  return a, b
end

local meAddr = findAddr("me_interface") or findAddr("me_controller")
if not meAddr then
  print("No me_interface/me_controller found. Aborting.")
  return
end

local function cleanLabel(label)
  if not label then return "?" end
  return (label:gsub("%$[0-9a-fk-or]", ""))
end

-- Describes a value without invoking it. On this bridge a "method" arrives as
-- a table carrying a __call metamethod, so plain type() is not enough to tell
-- data from behaviour.
local function describe(v)
  local t = type(v)
  if t ~= "table" then return t .. "(" .. tostring(v) .. ")" end
  local mt = getmetatable(v)
  if mt and type(mt.__call) == "function" then return "CALLABLE" end
  return "table"
end

-- Recursively prints a value's structure. Never calls anything.
local function dump(obj, indent, depth, seen)
  indent, depth = indent or "  ", depth or 1
  seen = seen or {}

  if type(obj) ~= "table" then
    print(indent .. describe(obj))
    return
  end
  if seen[obj] then print(indent .. "<cycle>") return end
  seen[obj] = true

  local empty = true
  for k, v in pairs(obj) do
    empty = false
    print(indent .. tostring(k) .. " = " .. describe(v))
    if type(v) == "table" and depth < MAX_DEPTH and not getmetatable(v) then
      dump(v, indent .. "  ", depth + 1, seen)
    end
  end
  if empty then print(indent .. "(no keys via pairs)") end

  -- pairs() often shows nothing for a proxied object; the metatable's __index
  -- is where the real surface lives.
  local mt = getmetatable(obj)
  if mt then
    print(indent .. "[metatable] __call=" .. type(mt.__call)
      .. "  __index=" .. type(mt.__index))
    if type(mt.__index) == "table" and depth < MAX_DEPTH then
      print(indent .. "[__index contents]")
      dump(mt.__index, indent .. "  ", depth + 1, seen)
    end
  end
end

-- Reports which of these names exist on `obj`, and what they are, WITHOUT
-- calling any of them. Anything appearing here is a candidate for a better
-- cancellation reason than factory.lua's current guess.
local CANDIDATES = {
  "isDone", "isCanceled", "isCancelled", "cancel", "getId", "id",
  "isStandalone", "getOutput", "output", "getStatus", "status",
  "getReason", "reason", "getError", "error", "getRemaining", "remaining",
  "getElapsed", "getProgress", "progress", "getMissingIngredient",
}

local function probeNames(obj)
  print("  known-name probe (nothing is invoked):")
  local found = false
  for _, name in ipairs(CANDIDATES) do
    local ok, v = pcall(function() return obj[name] end)
    if ok and v ~= nil then
      found = true
      print("    ." .. name .. " = " .. describe(v))
    end
  end
  if not found then print("    (none of the probed names are present)") end
end

-- ============================ part 1: CPUs (safe) ===========================

print(string.rep("=", 64))
print("PART 1 — getCpus() structure (read-only)")
print(string.rep("=", 64))

local cpus, cpuErr = safeCall(meAddr, "getCpus")
if not cpus then
  print("getCpus() failed: " .. tostring(cpuErr))
else
  local n = 0
  for i, cpu in ipairs(cpus) do
    n = i
    print("")
    print("CPU [" .. i .. "]")
    dump(cpu, "  ", 1, nil)
    probeNames(cpu)
  end
  if n == 0 then print("getCpus() returned no array entries.") end
end

-- ====================== part 2: a real job handle (opt-in) ==================

print("")
print(string.rep("=", 64))
print("PART 2 — crafting job handle")
print(string.rep("=", 64))

if not PROBE_ITEM then
  print("Skipped. PROBE_ITEM is nil.")
  print("")
  print("To run it: edit this file, set PROBE_ITEM to the label of something")
  print("cheap you don't mind crafting ONE of, then run diag_job again.")
  print("It requests a single unit purely to inspect the handle it returns,")
  print("and cancels it afterwards if the handle allows that.")
  return
end

local craftables = safeCall(meAddr, "getCraftables")
if not craftables then
  print("getCraftables() failed. Aborting part 2.")
  return
end

-- Craftable entries carry no label of their own; identity needs getItemStack().
local match
for _, entry in ipairs(craftables) do
  local ok, stack = pcall(function() return entry.getItemStack() end)
  if ok and type(stack) == "table" then
    if cleanLabel(stack.label or stack.name) == PROBE_ITEM then
      match = entry
      break
    end
  end
end

if not match then
  print("No craftable matched '" .. tostring(PROBE_ITEM) .. "'.")
  print("Check the exact label as shown in factory.lua's storage list.")
  return
end

print("Requesting " .. PROBE_QTY .. " x " .. PROBE_ITEM .. " to inspect the handle...")
local ok, job = pcall(function() return match.request(PROBE_QTY) end)
if not ok then
  print("request() raised: " .. tostring(job))
  return
end
if job == nil then
  print("request() returned nil.")
  return
end

print("")
print("handle type: " .. describe(job))
print("")
print("[structure]")
dump(job, "  ", 1, nil)
print("")
probeNames(job)

-- Give the plan a moment to resolve, then read the two states factory.lua
-- already relies on, so their timing is visible too.
os.sleep(2)
local okd, done = pcall(function() return job.isDone() end)
local okc, canceled = pcall(function() return job.isCanceled() end)
print("")
print("after 2s:  isDone -> " .. tostring(okd) .. "/" .. tostring(done)
  .. "   isCanceled -> " .. tostring(okc) .. "/" .. tostring(canceled))

-- Try to withdraw the probe craft so it doesn't quietly run to completion.
if type(job.cancel) ~= "nil" then
  local okCancel, res = pcall(function() return job.cancel() end)
  print("cancel() -> ok=" .. tostring(okCancel) .. " result=" .. tostring(res))
else
  print("No cancel() on the handle — the probe craft will run to completion.")
end

print("")
print("Done. Paste this output back; anything under the name probe that")
print("distinguishes 'too big' from 'missing ingredient' lets factory.lua")
print("stop guessing at why a job was cancelled.")
