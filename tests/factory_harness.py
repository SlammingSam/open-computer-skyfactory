"""Drive bin/factory.lua's auto-crafting against a simulated ME network.

factory.lua is the largest program here and had no tests at all, while its
auto-craft rules are the part that cost the most in-game debugging: firing on a
failed ME read, two CPUs deadlocking on one recipe, a surplus rule crafting
more of the thing it was meant to consume, rules colliding because they were
keyed by item alone.

Everything the program knows about the network arrives through
component.invoke, which makes it a clean seam: stub that and the whole data
layer, rule evaluation and dispatch path can be run without Minecraft.

Run:  pip install lupa && python tests/factory_harness.py
"""
import os.path
import sys
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "bin", "factory.lua")

PRELUDE = r"""
-- ---- simulated OpenComputers + AE2 -----------------------------------------
_G.__now = 0
_G.__files = {}
_G.__me = {}          -- method name -> function, set per test
_G.__requests = {}    -- every entry.request(qty) that actually happened
_G.__beeps = 0        -- how many times the pause signal sounded
_G.__power = 1000
_G.__maxpower = 2000

local function ser(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return string.format("%q", v)
  else
    return tostring(v)
  end
end
local function unser(s)
  local f = load("return " .. s)
  if not f then return nil end
  local ok, v = pcall(f)
  return ok and v or nil
end

io.open = function(path, mode)
  mode = mode or "r"
  if mode:find("r") then
    local c = _G.__files[path]
    if c == nil then return nil end
    return { read = function() return c end, close = function() end,
             lines = function() return function() return nil end end }
  end
  local buf = {}
  return {
    write = function(_, s) buf[#buf + 1] = s end,
    close = function() _G.__files[path] = table.concat(buf) end,
  }
end

-- A craftable entry as the real bridge presents it: request and getItemStack
-- report type()=="table" and are invoked through a __call metamethod. Tests
-- use the same shape, so the calling convention is exercised rather than
-- assumed.
function __craftable(name, damage, label)
  local callable = function(fn) return setmetatable({}, { __call = function(_, ...) return fn(...) end }) end
  local entry = {}
  entry.getItemStack = callable(function()
    return { name = name, damage = damage, label = label }
  end)
  entry.request = callable(function(qty)
    _G.__requests[#_G.__requests + 1] = { label = label, qty = qty }
    return {
      isDone = function() return _G.__jobDone == true end,
      isCanceled = function() return _G.__jobCanceled == true end,
    }
  end)
  return entry
end

local stubs = {
  component = {
    list = function(ctype)
      local rows = {}
      if ctype == "me_interface" then rows = { "me-addr" }
      elseif ctype == "gpu" then rows = { "gpu-addr" }
      elseif ctype == nil then rows = { "me-addr", "gpu-addr" } end
      local i = 0
      return function() i = i + 1; return rows[i] end
    end,
    invoke = function(addr, method, ...)
      local fn = _G.__me[method]
      if fn then return fn(...) end
      return nil
    end,
  },
  event = { pull = function() return nil end },
  computer = {
    uptime = function() return _G.__now end,
    beep = function() _G.__beeps = (_G.__beeps or 0) + 1 end,
  },
  term = { clear = function() end, setCursor = function() end },
  unicode = { len = string.len, sub = string.sub },
  serialization = { serialize = ser, unserialize = unser },
  filesystem = {
    exists = function(p) return _G.__files[p] ~= nil end,
    remove = function(p) _G.__files[p] = nil; return true end,
    rename = function(a, b) _G.__files[b] = _G.__files[a]; _G.__files[a] = nil; return true end,
    makeDirectory = function() return true end,
    size = function(p) return #(_G.__files[p] or "") end,
  },
}

local realRequire = require
require = function(name)
  if stubs[name] then return stubs[name] end
  return realRequire(name)
end

os.sleep = function() end
"""

EXPORTS = """
return {
  state = state,
  settings = settings,
  defaultSettings = defaultSettings,
  mergeDefaults = mergeDefaults,
  sanitiseSettings = sanitiseSettings,
  refresh = refresh,
  loadCraftables = loadCraftables,
  evaluateAutoCraft = evaluateAutoCraft,
  handleSettingsKey = handleSettingsKey,
  ui = ui,
  findItemByKey = findItemByKey,
  freeCpuBudget = freeCpuBudget,
  quantityInFlight = quantityInFlight,
  pollJobs = pollJobs,
  requestCraft = requestCraft,
  stackKey = stackKey,
  setSettings = function(s) settings = s end,
}
"""


def load():
    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute(PRELUDE)
    src = open(SRC, encoding="utf-8").read()
    lines = src.split("\n")
    cut = next(i for i, l in enumerate(lines) if l.startswith("-- ============================ settings persistence"))
    cut_end = next(i for i, l in enumerate(lines) if l.startswith("-- ================================ main loop"))
    body = "\n".join(lines[:cut_end]) + EXPORTS
    return lua, lua.execute(body)


lua, F = load()
if F is None:
    print("FAILED to load factory.lua under the stubs")
    sys.exit(1)

failures = []


def check(name, cond, detail=""):
    if cond:
        print("  pass  " + name)
    else:
        print("  FAIL  " + name + ("  -> " + str(detail) if detail else ""))
        failures.append(name)


def set_network(items, cpus=None, craftables=None):
    """items: list of (name, damage, label, count). cpus: list of busy flags."""
    lua.execute("_G.__me = {}")
    me = lua.globals()["__me"]

    rows = lua.eval("{}")
    for i, (name, dmg, label, count) in enumerate(items, 1):
        rows[i] = lua.table_from({"name": name, "damage": dmg, "label": label, "size": count})
    me["getItemsInNetwork"] = lua.eval("function(rows) return function() return rows end end")(rows)

    craft = lua.eval("{}")
    for i, (name, dmg, label) in enumerate(craftables or [], 1):
        craft[i] = lua.globals()["__craftable"](name, dmg, label)
    me["getCraftables"] = lua.eval("function(c) return function() return c end end")(craft)

    cpurows = lua.eval("{}")
    for i, busy in enumerate(cpus or [], 1):
        cpurows[i] = lua.table_from({"busy": busy})
    me["getCpus"] = lua.eval("function(c) return function() return c end end")(cpurows)

    me["getStoredPower"] = lua.eval("function() return _G.__power end")
    me["getMaxStoredPower"] = lua.eval("function() return _G.__maxpower end")


def requests():
    r = lua.globals()["__requests"]
    return [(r[i]["label"], r[i]["qty"]) for i in range(1, len(r) + 1)]


def reset_requests():
    lua.execute("_G.__requests = {}")


def advance(seconds):
    lua.globals()["__now"] = lua.globals()["__now"] + seconds


def set_power(percent):
    lua.globals()["__power"] = percent * 20      # of a 2000 maximum
    lua.globals()["__maxpower"] = 2000


def beeps():
    return lua.globals()["__beeps"]


def reset_beeps():
    lua.execute("_G.__beeps = 0")


def configure(rules, enabled=True, maxBatch=1000, reserveCpus=1, checkSeconds=0,
              minPowerPct=0):
    s = F["settings"]
    ac = s["autoCraft"]
    ac["enabled"] = enabled
    ac["maxBatch"] = maxBatch
    ac["reserveCpus"] = reserveCpus
    ac["checkSeconds"] = checkSeconds
    ac["minPowerPct"] = minPowerPct
    ac["beep"] = True
    rows = lua.eval("{}")
    for i, r in enumerate(rules, 1):
        rows[i] = lua.table_from(r)
    ac["rules"] = rows
    F["state"]["autoCraftCheckedAt"] = None
    F["state"]["autoCraftBackoff"] = lua.eval("{}")
    F["state"]["jobs"] = lua.eval("{}")
    F["state"]["autoCraftPowerPaused"] = None


# Two items, both craftable, so rules can target either.
QUARTZ = ("minecraft:quartz", 0, "Nether Quartz")
BLOCK = ("minecraft:quartz_block", 0, "Block of Quartz")
IRON = ("minecraft:iron_ingot", 0, "Iron Ingot")

QKEY = "minecraft:quartz#0"
BKEY = "minecraft:quartz_block#0"
IKEY = "minecraft:iron_ingot#0"


def prime(quartz=40000, blocks=0, iron=0, cpus=(False, False, False)):
    set_network(
        items=[QUARTZ + (quartz,), BLOCK + (blocks,), IRON + (iron,)],
        cpus=list(cpus),
        craftables=[QUARTZ, BLOCK, IRON])
    F["loadCraftables"]()
    F["refresh"]()
    reset_requests()


print("== the data layer ==")
prime()
check("items come through with their counts",
      F["findItemByKey"](QKEY)["count"] == 40000,
      F["findItemByKey"](QKEY)["count"] if F["findItemByKey"](QKEY) else None)
check("a stack key is name#damage", F["stackKey"](lua.table_from(
    {"name": "minecraft:quartz", "damage": 0})) == QKEY)
check("craftable entries are attached to their items",
      F["findItemByKey"](BKEY)["craftEntry"] is not None)
check("a successful read sets lastOk", F["state"]["lastOk"] is True)

print("== below rules ==")
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}])
F["evaluateAutoCraft"]()
check("a below rule fires when stock is under the threshold",
      requests() == [("Iron Ingot", 64)], requests())

prime(iron=500)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}])
F["evaluateAutoCraft"]()
check("and does nothing when stock is above it", requests() == [], requests())

print("== above rules: the surplus conversion ==")
# The scenario this feature was built for: 40,000 quartz, convert everything
# over 35,000 into blocks at 4 quartz per block, keeping 5,000 loose.
prime(quartz=40000)
configure([{"key": QKEY, "label": "Nether Quartz", "direction": "above",
            "threshold": 35000, "keep": 5000, "ratio": 4,
            "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True}],
          maxBatch=100000)
F["evaluateAutoCraft"]()
check("a surplus rule crafts the TARGET, not the watched item",
      requests() and requests()[0][0] == "Block of Quartz", requests())
check("quantity is (count - keep) / ratio",
      requests() == [("Block of Quartz", (40000 - 5000) // 4)], requests())

prime(quartz=30000)
configure([{"key": QKEY, "label": "Nether Quartz", "direction": "above",
            "threshold": 35000, "keep": 5000, "ratio": 4,
            "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True}])
F["evaluateAutoCraft"]()
check("and stays quiet below the threshold", requests() == [], requests())

print("== batch caps ==")
prime(quartz=40000)
configure([{"key": QKEY, "label": "Nether Quartz", "direction": "above",
            "threshold": 35000, "keep": 5000, "ratio": 4,
            "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True}],
          maxBatch=1500)
F["evaluateAutoCraft"]()
check("the global cap limits a single request",
      requests() == [("Block of Quartz", 1500)], requests())

prime(quartz=40000)
configure([{"key": QKEY, "label": "Nether Quartz", "direction": "above",
            "threshold": 35000, "keep": 5000, "ratio": 4, "maxBatch": 250,
            "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True}],
          maxBatch=1500)
F["evaluateAutoCraft"]()
check("a per-rule cap overrides the global one",
      requests() == [("Block of Quartz", 250)], requests())

print("== the guards ==")
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}], enabled=False)
F["evaluateAutoCraft"]()
check("the master switch stops everything", requests() == [], requests())

prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": False}])
F["evaluateAutoCraft"]()
check("a disabled rule does nothing", requests() == [], requests())

# A failed ME read leaves every count reading 0, which every below rule would
# treat as "empty, craft now". This fired spuriously on a transient hiccup.
prime(iron=500)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}])
lua.execute("_G.__me.getItemsInNetwork = function() return nil end")
F["refresh"]()
reset_requests()
F["evaluateAutoCraft"]()
check("a failed ME read fires nothing", requests() == [], requests())
check("and is recorded as a failed read", F["state"]["lastOk"] is False)

print("== one job per rule ==")
prime(quartz=40000)
configure([{"key": QKEY, "label": "Nether Quartz", "direction": "above",
            "threshold": 35000, "keep": 5000, "ratio": 4,
            "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True}],
          maxBatch=100)
F["evaluateAutoCraft"]()
first = len(requests())
F["state"]["autoCraftCheckedAt"] = None   # let the interval pass again
F["evaluateAutoCraft"]()
check("a second pass does not stack another job on the same rule",
      len(requests()) == first, requests())

print("== CPU budget ==")
# Two rules, one free CPU after the reserve: only one may dispatch.
prime(iron=10, quartz=40000, cpus=(False, False))
configure([
    {"key": IKEY, "label": "Iron Ingot", "direction": "below",
     "threshold": 100, "craftQty": 64, "enabled": True},
    {"key": QKEY, "label": "Nether Quartz", "direction": "above",
     "threshold": 35000, "keep": 5000, "ratio": 4,
     "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True},
], reserveCpus=1)
check("the reserve is held back from the budget", F["freeCpuBudget"]() == 1,
      F["freeCpuBudget"]())
F["evaluateAutoCraft"]()
check("only as many rules dispatch as there are free CPUs",
      len(requests()) == 1, requests())

prime(iron=10, cpus=(True, True))
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}], reserveCpus=1)
check("a fully busy network has no budget", F["freeCpuBudget"]() == 0)
F["evaluateAutoCraft"]()
check("and dispatches nothing", requests() == [], requests())

prime(iron=10, cpus=())
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}])
check("no CPU data degrades to serial crafting, not to nothing",
      F["freeCpuBudget"]() == 1)

print("== backing off a cancelled rule ==")
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
            "threshold": 100, "craftQty": 64, "enabled": True}])
lua.execute("_G.__jobCanceled = true")
F["evaluateAutoCraft"]()
check("the first attempt goes out", len(requests()) == 1, requests())
F["pollJobs"]()                     # AE2 cancels it
advance(1)
F["state"]["autoCraftCheckedAt"] = None
F["evaluateAutoCraft"]()
check("a cancelled rule is not retried immediately",
      len(requests()) == 1, requests())
lua.execute("_G.__jobCanceled = false")

print("== rules are keyed by item AND direction ==")
# Two rules on the same item pulling in opposite directions must not share a
# backoff slot or overwrite each other.
prime(quartz=40000, cpus=(False, False, False, False))
configure([
    {"key": QKEY, "label": "Nether Quartz", "direction": "above",
     "threshold": 35000, "keep": 5000, "ratio": 4,
     "craftKey": BKEY, "craftLabel": "Block of Quartz", "enabled": True},
    {"key": QKEY, "label": "Nether Quartz", "direction": "below",
     "threshold": 50000, "craftQty": 100, "enabled": True},
], maxBatch=100, reserveCpus=1)
F["evaluateAutoCraft"]()
labels = sorted(r[0] for r in requests())
check("both directions on one item can fire independently",
      labels == ["Block of Quartz", "Nether Quartz"], requests())

print("== settings ==")
d = F["defaultSettings"]()
check("defaults are sane",
      d["autoCraft"]["enabled"] is False and d["autoCraft"]["maxBatch"] == 1000)

loaded = lua.table_from({"autoCraft": lua.table_from({"enabled": True})})
merged = F["mergeDefaults"](loaded, F["defaultSettings"]())
check("merging fills in keys a new version added",
      merged["autoCraft"]["maxBatch"] == 1000)
check("without disturbing what was already saved",
      merged["autoCraft"]["enabled"] is True)

print("== the power floor ==")
# AE2 crafting is what drains the network, so the useful moment to stop is
# before starting more of it. Off by default, so upgrading cannot halt a setup
# that was working.
set_power(100)
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
             "threshold": 100, "craftQty": 64, "enabled": True}], minPowerPct=0)
F["evaluateAutoCraft"]()
check("a floor of zero disables the check", requests() == [("Iron Ingot", 64)], requests())

set_power(30)
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
             "threshold": 100, "craftQty": 64, "enabled": True}], minPowerPct=50)
reset_beeps()
F["evaluateAutoCraft"]()
check("nothing is dispatched below the floor", requests() == [], requests())
check("and the pause is sounded once", beeps() == 1, beeps())

F["state"]["autoCraftCheckedAt"] = None
F["evaluateAutoCraft"]()
check("a continuing shortage is not re-announced every pass", beeps() == 1, beeps())

set_power(80)
F["refresh"]()
reset_requests()
F["state"]["autoCraftCheckedAt"] = None
F["evaluateAutoCraft"]()
check("crafting resumes once power recovers",
      requests() == [("Iron Ingot", 64)], requests())

set_power(10)
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
             "threshold": 100, "craftQty": 64, "enabled": True}], minPowerPct=50)
reset_beeps()
F["evaluateAutoCraft"]()
check("a later dip is announced again", beeps() == 1, beeps())

set_power(100)
prime(iron=10)
configure([{"key": IKEY, "label": "Iron Ingot", "direction": "below",
             "threshold": 100, "craftQty": 64, "enabled": True}], minPowerPct=50)
F["settings"]["autoCraft"]["beep"] = False
set_power(10)
F["refresh"]()
reset_beeps()
F["state"]["autoCraftPowerPaused"] = None
F["state"]["autoCraftCheckedAt"] = None
F["evaluateAutoCraft"]()
check("beeping can be turned off", beeps() == 0, beeps())
check("but the pause still happened", F["state"]["autoCraftPowerPaused"] is True,
      F["state"]["autoCraftPowerPaused"])
F["settings"]["autoCraft"]["beep"] = True
set_power(100)

print("== reordering rules ==")
# Rules dispatch in list order, so with a finite CPU budget one near the top
# can take the last free CPU on every pass and starve everything below it.
prime(iron=10)
configure([
    {"key": IKEY, "label": "First", "direction": "below",
     "threshold": 100, "craftQty": 1, "enabled": True},
    {"key": IKEY, "label": "Second", "direction": "below",
     "threshold": 100, "craftQty": 2, "enabled": True},
    {"key": IKEY, "label": "Third", "direction": "below",
     "threshold": 100, "craftQty": 3, "enabled": True},
])


def order():
    rs = F["settings"]["autoCraft"]["rules"]
    return [rs[i]["label"] for i in range(1, len(rs) + 1)]


F["ui"]["acSelected"] = 1
F["handleSettingsKey"](ord("J"), 0)
check("Shift+J moves the selected rule down",
      order() == ["Second", "First", "Third"], order())
check("and the selection follows it", F["ui"]["acSelected"] == 2,
      F["ui"]["acSelected"])

F["handleSettingsKey"](ord("K"), 0)
check("Shift+K moves it back up",
      order() == ["First", "Second", "Third"], order())
check("and the selection follows again", F["ui"]["acSelected"] == 1)

F["ui"]["acSelected"] = 1
F["handleSettingsKey"](ord("K"), 0)
check("moving up from the top does nothing",
      order() == ["First", "Second", "Third"], order())
check("and leaves the selection alone", F["ui"]["acSelected"] == 1)

F["ui"]["acSelected"] = 3
F["handleSettingsKey"](ord("J"), 0)
check("moving down from the bottom does nothing",
      order() == ["First", "Second", "Third"], order())

# Lowercase must still move the cursor rather than the rule.
F["ui"]["acSelected"] = 1
F["handleSettingsKey"](ord("j"), 0)
check("lowercase j still moves the cursor, not the rule",
      order() == ["First", "Second", "Third"] and F["ui"]["acSelected"] == 2,
      (order(), F["ui"]["acSelected"]))

print("== settings that came off disk damaged ==")
# Settings are read from a file that can be hand-edited or half-written. Every
# consumer guards its numbers, but a rule that is not a table, or a direction
# that is neither below nor above, would still crash the evaluation loop on the
# next tick -- which happens unattended, minutes after the bad save.
san = F["sanitiseSettings"]

check("a non-table becomes defaults",
      san("nonsense")["autoCraft"]["maxBatch"] == 1000)

broken = lua.table_from({"autoCraft": "not a table"})
check("a non-table autoCraft is replaced",
      san(broken)["autoCraft"]["enabled"] is False)

s2 = F["defaultSettings"]()
s2["autoCraft"]["rules"] = "not a list"
check("a non-list rules becomes an empty list",
      len(san(s2)["autoCraft"]["rules"]) == 0)

def rules_after(raw_rules):
    cfg = F["defaultSettings"]()
    rows = lua.eval("{}")
    for i, r in enumerate(raw_rules, 1):
        rows[i] = r if isinstance(r, str) else lua.table_from(r)
    cfg["autoCraft"]["rules"] = rows
    out = san(cfg)["autoCraft"]["rules"]
    return [out[i] for i in range(1, len(out) + 1)]

kept = rules_after([
    "a string where a rule should be",
    {"key": "x", "direction": "sideways", "threshold": 1},
    {"key": "y", "direction": "below"},
    {"direction": "below", "threshold": 1},
    {"key": "good", "direction": "below", "threshold": "250", "craftQty": "64"},
])
check("only the usable rule survives", len(kept) == 1, len(kept))
check("a string threshold is coerced to a number",
      kept[0]["threshold"] == 250, kept[0]["threshold"])
check("so is a string quantity", kept[0]["craftQty"] == 64, kept[0]["craftQty"])
check("a rule with no explicit enabled defaults to on", kept[0]["enabled"] is True)

kept = rules_after([{"key": "k", "direction": "above", "threshold": 10,
                     "keep": -5, "ratio": 0}])
check("a negative keep is floored at zero", kept[0]["keep"] == 0, kept[0]["keep"])
check("a zero ratio is raised to one, never dividing by zero",
      kept[0]["ratio"] == 1, kept[0]["ratio"])

kept = rules_after([{"key": "k", "direction": "below", "threshold": 1, "maxBatch": 0}])
check("a zero per-rule cap is cleared rather than capping at zero",
      kept[0]["maxBatch"] is None, kept[0]["maxBatch"])
kept = rules_after([{"key": "k", "direction": "below", "threshold": 1, "maxBatch": "500"}])
check("a string per-rule cap is coerced", kept[0]["maxBatch"] == 500, kept[0]["maxBatch"])

bad = F["defaultSettings"]()
bad["autoCraft"]["maxBatch"] = 0
bad["autoCraft"]["checkSeconds"] = "soon"
bad["autoCraft"]["reserveCpus"] = -3
fixed = san(bad)["autoCraft"]
check("a global below its floor resets to the default", fixed["maxBatch"] == 1000,
      fixed["maxBatch"])
check("a non-numeric interval resets", fixed["checkSeconds"] == 15, fixed["checkSeconds"])
check("a negative reserve resets", fixed["reserveCpus"] == 1, fixed["reserveCpus"])

bad2 = F["defaultSettings"]()
bad2["autoCraft"]["enabled"] = "yes"
check("a non-boolean enabled is forced to a boolean, not left truthy",
      san(bad2)["autoCraft"]["enabled"] is False)

pw = F["defaultSettings"]()
pw["autoCraft"]["minPowerPct"] = 500
check("a power floor above 100 is clamped",
      san(pw)["autoCraft"]["minPowerPct"] == 100, san(pw)["autoCraft"]["minPowerPct"])
pw2 = F["defaultSettings"]()
pw2["autoCraft"]["minPowerPct"] = "lots"
check("a non-numeric power floor becomes off",
      san(pw2)["autoCraft"]["minPowerPct"] == 0)
pw3 = F["defaultSettings"]()
pw3["autoCraft"]["minPowerPct"] = -10
check("a negative power floor becomes off",
      san(pw3)["autoCraft"]["minPowerPct"] == 0)

# The point of all this: evaluation must survive whatever was on disk.
prime(iron=10)
cfg = F["defaultSettings"]()
rows = lua.eval("{}")
rows[1] = "garbage"
rows[2] = lua.table_from({"key": IKEY, "label": "Iron Ingot", "direction": "below",
                          "threshold": "100", "craftQty": "64", "enabled": True})
cfg["autoCraft"]["rules"] = rows
cfg["autoCraft"]["enabled"] = True
cfg["autoCraft"]["checkSeconds"] = 0
F["setSettings"](san(cfg))
F["state"]["autoCraftCheckedAt"] = None
reset_requests()
F["evaluateAutoCraft"]()
check("a damaged rules list still evaluates the good rules",
      requests() == [("Iron Ingot", 64)], requests())

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
