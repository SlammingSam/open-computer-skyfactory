-- factory.lua — AE2 ME network dashboard for OpenComputers (MC 1.12.2)
-- Standalone; no dependencies beyond OC's own APIs. Pull updates in-game
-- with update.lua rather than pasting through `edit` (which truncates
-- around 8,491 bytes).

local component = require("component")
local event     = require("event")
local computer  = require("computer")
local term      = require("term")

-- OC ships a `unicode` API; box-drawing glyphs are multi-byte, so plain
-- string.sub would slice them in half when truncating.
local uni; pcall(function() uni = require("unicode") end)
local ulen = uni and uni.len or string.len
local usub = uni and uni.sub or string.sub

-- ============================ component plumbing ============================
-- This bridge does not support calling methods off a component proxy
-- (component.me_interface.getX() / component.proxy(addr).method()) — it
-- silently returns nothing even when component.methods() lists the method.
-- Everything therefore goes through component.invoke.

local function findAddr(ctype)
  for addr in component.list(ctype, true) do return addr end
end

local function safeCall(addr, method, ...)
  if not addr then return nil, "no component address" end
  local r = table.pack(pcall(component.invoke, addr, method, ...))
  if not r[1] then return nil, tostring(r[2]) end
  return table.unpack(r, 2, r.n)
end

local meAddr  = findAddr("me_interface") or findAddr("me_controller")
local gpuAddr = findAddr("gpu")

if not gpuAddr then
  print("No GPU component found — this dashboard needs a bound screen.")
  return
end

-- Labels on this bridge carry literal "$" + code-letter artifacts in place
-- of real Minecraft formatting codes (e.g. "$6Coal$r" -> "Coal").
local function cleanLabel(label)
  if not label then return "?" end
  return (label:gsub("%$[0-9a-fk-or]", ""))
end

-- ================================= palette ==================================

local C = {
  bg        = 0x000000,
  headerBg  = 0x00506B,
  headerFg  = 0xAEEBFF,
  border    = 0x2E4C59,
  label     = 0x7C8F9B,
  text      = 0xC9D7DF,
  accent    = 0x00D3F2,
  good      = 0x4CD964,
  warn      = 0xFFB300,
  bad       = 0xFF4136,
  selBg     = 0x11485C,
  selFg     = 0xFFFFFF,
  craft     = 0xB07CFF,
  zero      = 0x556570,
  barFill   = 0x0E7C8C,
  barTrack  = 0x1E3038,
}

-- Collections coming back over this bridge are not always clean arrays: they
-- can carry a trailing count field (n = 136) or other scalars alongside the
-- array part, so a bare pairs() loop yields numbers where tables are expected.
-- Prefer the sequential part, and fall back to a filtered pairs() only if the
-- bridge handed back non-sequential keys.
local function tableEntries(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for _, v in ipairs(t) do
    if type(v) == "table" then out[#out + 1] = v end
  end
  if #out == 0 then
    for _, v in pairs(t) do
      if type(v) == "table" then out[#out + 1] = v end
    end
  end
  return out
end

-- ============================== draw helpers ================================

local W, H = 80, 25
local origW, origH

local function fg(c) safeCall(gpuAddr, "setForeground", c) end
local function bg(c) safeCall(gpuAddr, "setBackground", c) end
local function gset(x, y, s) safeCall(gpuAddr, "set", x, y, s) end
local function gfill(x, y, w, h, ch) safeCall(gpuAddr, "fill", x, y, w, h, ch) end

-- Truncate-or-pad to an exact display width (unicode-safe).
local function fit(s, width)
  s = tostring(s or "")
  local l = ulen(s)
  if l > width then return usub(s, 1, width) end
  return s .. string.rep(" ", width - l)
end

local function ralign(s, width)
  s = tostring(s or "")
  local l = ulen(s)
  if l > width then return usub(s, 1, width) end
  return string.rep(" ", width - l) .. s
end

local function comma(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local grouped = s:reverse():gsub("(%d%d%d)", "%1,")
  return (grouped:reverse():gsub("^,", ""))
end

local function shortNum(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
  if n >= 1000000    then return string.format("%.2fM", n / 1000000) end
  if n >= 1000       then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

-- =============================== data layer =================================

-- The view (filter + sort) is rebuilt only when something that affects it
-- changes, rather than on every render and every keypress. Declared here so
-- refresh() can invalidate it.
local viewCache, viewDirty = {}, true
local function invalidateView() viewDirty = true end

local state = {
  items = {},        -- {label, count, craftEntry}
  power = 0, maxPower = 0,
  cpus = {}, cpuBusy = 0,
  craftSet = {},     -- "name#damage" -> {entry = ..., label = ...}
  craftableCount = 0,
  err = nil,
  lastOk = false,
  craftLoadedAt = nil,
}

-- Identity key for a stack. In 1.12.2 `damage` is the variant discriminator
-- (plank woods, wool colours), so name alone would collide across variants.
-- Falls back to the cleaned label when the bridge gives no name.
local function stackKey(t)
  if type(t) ~= "table" then return nil end
  local name = t.name
  if name and name ~= "" then
    return tostring(name) .. "#" .. tostring(math.floor(tonumber(t.damage) or 0))
  end
  local label = cleanLabel(t.label)
  if label and label ~= "" and label ~= "?" then return "label:" .. label end
  return nil
end

-- Craftable entries carry NO .label and NO .name of their own — the live
-- diagnostic showed every one reporting "label=?". Identity is only available
-- by calling getItemStack() on each, which costs one bridge round-trip per
-- entry (152 of them on this network). That is far too slow for the 3s
-- refresh, so the catalogue is loaded separately and cached.
local CRAFT_RELOAD_SECONDS = 120

local function loadCraftables(onProgress)
  local entries = tableEntries(safeCall(meAddr, "getCraftables"))
  local craftSet, nCraft = {}, 0

  for i, entry in ipairs(entries) do
    -- getItemStack is a table with a hidden __call metamethod; calling it
    -- normally is confirmed working against the live bridge.
    local ok, stack = pcall(function() return entry.getItemStack() end)
    if ok and type(stack) == "table" then
      local key = stackKey(stack)
      if key and not craftSet[key] then
        craftSet[key] = {entry = entry, label = cleanLabel(stack.label or stack.name)}
        nCraft = nCraft + 1
      end
    end
    if onProgress and (i % 25 == 0 or i == #entries) then onProgress(i, #entries) end
  end

  state.craftSet = craftSet
  state.craftableCount = nCraft
  state.craftLoadedAt = computer.uptime()
end

local function refresh()
  if not meAddr then
    state.err = "no me_interface / me_controller component found"
    state.lastOk = false
    return
  end

  local rawItems, err = safeCall(meAddr, "getItemsInNetwork")
  if not rawItems then
    state.err = "getItemsInNetwork failed: " .. tostring(err)
    state.lastOk = false
    rawItems = {}
  else
    state.err = nil
    state.lastOk = true
  end

  local items, seen = {}, {}
  for _, it in ipairs(tableEntries(rawItems)) do
    local key = stackKey(it)
    local craft = key and state.craftSet[key] or nil
    items[#items + 1] = {
      label = cleanLabel(it.label or it.name or "?"),
      count = tonumber(it.size or it.count) or 0,
      craftEntry = craft and craft.entry or nil,
    }
    if key then seen[key] = true end
  end

  -- Surface craftables the network holds none of, so you can still order
  -- something you have zero of — otherwise they'd be invisible and unorderable.
  for key, c in pairs(state.craftSet) do
    if not seen[key] then
      items[#items + 1] = {label = c.label, count = 0, craftEntry = c.entry}
    end
  end

  state.items = items
  invalidateView()

  state.power    = tonumber(safeCall(meAddr, "getStoredPower")) or 0
  state.maxPower = tonumber(safeCall(meAddr, "getMaxStoredPower")) or 0

  local cpus = tableEntries(safeCall(meAddr, "getCpus"))
  state.cpus = cpus
  local busy = 0
  for _, c in ipairs(cpus) do if c.busy then busy = busy + 1 end end
  state.cpuBusy = busy
end

-- ============================ auto-crafting (gated) =========================
-- getCraftables() entries report type(entry.request) == "table", not
-- Calling convention CONFIRMED against the live network by diag_craft2.lua:
-- entry.request and entry.getItemStack report type()=="table", but both carry
-- a metatable whose __call is a function, and entry.getItemStack() invoked as
-- a plain call succeeded and returned a real stack. entry.request(qty) uses
-- the same mechanism.
local CRAFT_CONFIRMED = true

local function requestCraft(entry, qty)
  if not CRAFT_CONFIRMED then
    return false, "crafting locked — run diag_craft2.lua first"
  end
  if type(entry) ~= "table" then
    return false, "no craftable entry for this item"
  end

  local ok, result = pcall(function() return entry.request(qty) end)
  if not ok then return false, tostring(result) end
  if result == nil then
    return false, "request() returned nil — call convention may have changed"
  end

  -- AE2 hands back a craft-status object. Report whatever it says rather than
  -- assuming the job was accepted just because the call did not error.
  local note = ""
  if type(result) == "table" then
    local okc, canceled = pcall(function() return result.isCanceled() end)
    if okc and canceled == true then
      return false, "ME network refused the job (reported canceled)"
    end
  end
  return true, note
end

-- ================================ UI state ==================================

-- Sort modes, cycled with `s`. Every comparator falls back to name so the
-- order is total and stable-looking rather than arbitrary within ties.
local function byName(a, b) return a.label:lower() < b.label:lower() end

local SORTS = {
  {label = "name A-Z", cmp = byName},
  {label = "name Z-A", cmp = function(a, b) return a.label:lower() > b.label:lower() end},
  {label = "qty high", cmp = function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return byName(a, b)
  end},
  {label = "qty low", cmp = function(a, b)
    if a.count ~= b.count then return a.count < b.count end
    return byName(a, b)
  end},
  {label = "craftable", cmp = function(a, b)
    local ac, bc = a.craftEntry ~= nil, b.craftEntry ~= nil
    if ac ~= bc then return ac end
    return byName(a, b)
  end},
}

local ui = {
  top = 1, selected = 1,
  filterText = "", filterMode = false,
  craftMode = false, craftQty = "", craftTarget = nil,
  status = nil, statusKind = "info",   -- info | good | bad
  sort = 1,
}

local function setStatus(msg, kind)
  ui.status = msg
  ui.statusKind = kind or "info"
end

local function filteredItems()
  if not viewDirty then return viewCache end

  local out
  if ui.filterText == "" then
    out = {}
    for i, it in ipairs(state.items) do out[i] = it end
  else
    local needle = ui.filterText:lower()
    out = {}
    for _, it in ipairs(state.items) do
      if it.label:lower():find(needle, 1, true) then out[#out + 1] = it end
    end
  end

  table.sort(out, SORTS[ui.sort].cmp)
  viewCache, viewDirty = out, false
  return viewCache
end

-- ================================ rendering =================================

local LIST_TOP = 8            -- first item row
local function listBottom() return H - 2 end
local function visibleRows() return listBottom() - LIST_TOP + 1 end

local function drawHeader()
  bg(C.headerBg); gfill(1, 1, W, 1, " ")
  fg(C.headerFg); gset(2, 1, "◆ ME NETWORK")

  -- Right side: link state, plus an explicit crafting-lock indicator so the
  -- gate is visible rather than a silent surprise at craft time.
  local right = CRAFT_CONFIRMED and "CRAFT ARMED" or "CRAFT LOCKED"
  local link  = state.lastOk and "● ONLINE" or "● OFFLINE"
  fg(state.lastOk and C.good or C.bad)
  gset(W - ulen(right) - ulen(link) - 4, 1, link)
  fg(CRAFT_CONFIRMED and C.warn or C.label)
  gset(W - ulen(right) - 1, 1, right)
end

local function drawPower()
  bg(C.bg); gfill(1, 2, W, 1, " ")
  fg(C.label); gset(2, 2, "POWER")

  local pct = 0
  if state.maxPower and state.maxPower > 0 then
    pct = math.max(0, math.min(1, state.power / state.maxPower))
  end

  local barW = math.max(10, math.min(30, W - 50))
  local filled = math.floor(pct * barW + 0.5)
  local barColor = (pct > 0.5 and C.good) or (pct > 0.2 and C.warn) or C.bad

  fg(C.border); gset(9, 2, "▐")
  fg(barColor); gset(10, 2, string.rep("█", filled))
  fg(C.border)
  gset(10 + filled, 2, string.rep("░", barW - filled))
  gset(10 + barW, 2, "▌")

  -- Percentage sits next to its own bar, not stranded across the screen.
  fg(barColor)
  gset(12 + barW, 2, string.format("%d%%", math.floor(pct * 100 + 0.5)))

  -- Full-precision figure right-aligned, balancing the stats row below.
  local exact = comma(state.power) .. " / " .. comma(state.maxPower) .. " AE"
  fg(C.text); gset(W - ulen(exact) - 1, 2, exact)
end

local function drawStats()
  bg(C.bg); gfill(1, 3, W, 1, " ")
  fg(C.label); gset(2, 3, "CPUS")

  -- One glyph per crafting CPU: filled = busy, hollow = idle.
  local x = 9
  local shown = math.min(#state.cpus, 12)
  for i = 1, shown do
    local c = state.cpus[i]
    fg(c.busy and C.warn or C.border)
    gset(x, 3, c.busy and "▰" or "▱")
    x = x + 1
  end
  if #state.cpus == 0 then fg(C.zero); gset(x, 3, "none"); x = x + 4 end

  fg(C.label)
  gset(x + 2, 3, string.format("%d/%d busy", state.cpuBusy, #state.cpus))

  local rightInfo = string.format("TYPES %s    CRAFTABLE %s",
    comma(#state.items), comma(state.craftableCount))
  fg(C.text); gset(W - ulen(rightInfo) - 1, 3, rightInfo)
end

-- Single source of truth for table geometry, so the header row and the data
-- rows can never drift out of alignment. The relative-quantity bar absorbs
-- surplus width on wide screens instead of leaving a dead gap.
local function columns()
  local tag, stored, gap = 9, 13, 2
  local avail = W - 4 - 2                          -- interior, minus the marker
  local rest  = avail - tag - stored - gap * 3
  -- Cap the name column at a width that comfortably holds long modded item
  -- names; the bar takes the remainder rather than leaving a dead gap.
  local name  = math.min(44, math.floor(rest * 0.7))
  local bar   = rest - name
  if bar < 10 then bar = 0 name = rest + gap end   -- too narrow to read; drop it

  local c = {name = name, stored = stored, bar = bar, tag = tag, gap = gap}
  c.xName   = 5
  c.xStored = c.xName + name
  c.xBar    = c.xStored + stored + gap
  c.xTag    = (bar > 0) and (c.xBar + bar + gap) or (c.xStored + stored + gap)
  return c
end

-- Log scale: an ME network spans single items to seven-figure cobblestone,
-- so a linear bar would render everything but the largest stack as empty.
local function barFrac(v, maxv)
  if not maxv or maxv <= 0 then return 0 end
  local lm = math.log(maxv + 1)
  if lm <= 0 then return 0 end
  return math.max(0, math.min(1, math.log((v or 0) + 1) / lm))
end

local function drawListFrame()
  local title = "STORAGE · sort: " .. SORTS[ui.sort].label
  if ui.filterText ~= "" then title = title .. " · filter: " .. ui.filterText end

  bg(C.bg); fg(C.border)
  local lead = "─ " .. title .. " "
  gset(1, 5, "┌" .. lead .. string.rep("─", math.max(0, W - 2 - ulen(lead))) .. "┐")

  -- Column headings, positioned from the same geometry as the rows.
  local c = columns()
  gfill(1, 6, W, 1, " ")
  fg(C.border); gset(1, 6, "│"); gset(W, 6, "│")
  fg(C.label)
  gset(c.xName, 6, fit("ITEM", c.name))
  gset(c.xStored, 6, ralign("STORED", c.stored))

  fg(C.border)
  gset(1, 7, "├" .. string.rep("─", W - 2) .. "┤")
end

local function drawList()
  local list = filteredItems()
  local rows = visibleRows()

  -- Clamp selection and scroll window.
  if ui.selected > #list then ui.selected = math.max(1, #list) end
  if ui.selected < 1 then ui.selected = 1 end
  if ui.selected < ui.top then ui.top = ui.selected end
  if ui.selected > ui.top + rows - 1 then ui.top = ui.selected - rows + 1 end
  if ui.top < 1 then ui.top = 1 end

  local c = columns()

  -- Bars are scaled against the largest stock currently on screen, so a
  -- filtered view rescales to stay informative.
  local maxCount = 0
  for _, it in ipairs(list) do
    if it.count > maxCount then maxCount = it.count end
  end

  for r = 0, rows - 1 do
    local y = LIST_TOP + r
    local idx = ui.top + r
    local it = list[idx]
    local selected = (idx == ui.selected)
    local rowBg = selected and C.selBg or C.bg

    bg(rowBg)
    gfill(2, y, W - 2, 1, " ")
    fg(C.border); bg(C.bg)
    gset(1, y, "│"); gset(W, y, "│")

    if it then
      bg(rowBg)
      fg(selected and C.accent or C.border)
      gset(3, y, selected and "▸ " or "  ")

      fg(selected and C.selFg or C.text)
      gset(c.xName, y, fit(it.label, c.name))

      fg(it.count == 0 and C.zero or (selected and C.selFg or C.text))
      gset(c.xStored, y, ralign(comma(it.count), c.stored))

      if c.bar > 0 then
        local filled = math.floor(barFrac(it.count, maxCount) * c.bar + 0.5)
        if it.count > 0 and filled < 1 then filled = 1 end  -- never vanish
        fg(selected and C.accent or C.barFill)
        gset(c.xBar, y, string.rep("▬", filled))
        fg(C.barTrack)
        gset(c.xBar + filled, y, string.rep("·", c.bar - filled))
      end

      if it.craftEntry then
        fg(C.craft)
        gset(c.xTag, y, "✦ craft")
      end
    end
  end

  -- Scroll thumb in the right border, when the list overflows.
  if #list > rows then
    local span = rows - 1
    local pos = math.floor((ui.top - 1) / (#list - rows) * span + 0.5)
    bg(C.bg); fg(C.accent)
    gset(W, LIST_TOP + math.max(0, math.min(span, pos)), "█")
  end

  -- Empty-state message.
  if #list == 0 then
    bg(C.bg); fg(C.zero)
    local msg = ui.filterText ~= ""
      and ("no items match \"" .. ui.filterText .. "\"")
      or "ME network reports no items"
    gset(math.floor((W - ulen(msg)) / 2), LIST_TOP + 2, msg)
  end

  -- Bottom border carries the position indicator, so the panel's empty space
  -- still tells you where you are in the list.
  bg(C.bg); fg(C.border)
  local info
  if #list == 0 then
    info = " none "
  else
    local last = math.min(#list, ui.top + rows - 1)
    info = string.format(" %s–%s of %s ", comma(ui.top), comma(last), comma(#list))
    if ui.filterText ~= "" then
      info = string.format(" %s–%s of %s filtered ", comma(ui.top), comma(last), comma(#list))
    end
  end
  -- Draw the full rule, then overwrite its tail with the label.
  local ilen = ulen(info)
  local dashes = math.max(0, W - 3 - ilen)
  gset(1, H - 1, "└" .. string.rep("─", dashes + ilen) .. "─┘")
  fg(C.label); gset(2 + dashes, H - 1, info)
end

local function drawFooter()
  bg(C.bg); gfill(1, H, W, 1, " ")

  if ui.filterMode then
    fg(C.accent); gset(2, H, "FILTER ")
    fg(C.selFg);  gset(9, H, ui.filterText .. "_")
    fg(C.label)
    local hint = "Enter accept · Backspace edit"
    gset(W - ulen(hint) - 1, H, hint)
    return
  end

  if ui.craftMode then
    local name = ui.craftTarget and ui.craftTarget.label or "?"
    fg(C.craft); gset(2, H, "CRAFT ")
    fg(C.selFg); gset(8, H, name .. "  x" .. ui.craftQty .. "_")
    fg(C.label)
    local hint = "Enter confirm · Esc cancel"
    gset(W - ulen(hint) - 1, H, hint)
    return
  end

  if ui.status then
    fg((ui.statusKind == "bad" and C.bad)
       or (ui.statusKind == "good" and C.good)
       or C.label)
    gset(2, H, fit(ui.status, W - 2))
    return
  end

  if state.err then
    fg(C.bad); gset(2, H, fit("ERR " .. state.err, W - 2))
    return
  end

  -- Keybinding hints: keys in accent, descriptions dim.
  local hints = {
    {"R", "refresh"}, {"j/k", "move"}, {"/", "filter"}, {"S", "sort"},
    {"C", "craft"}, {"Esc", "clear"}, {"Q", "quit"},
  }
  local x = 2
  for _, h in ipairs(hints) do
    fg(C.accent); gset(x, H, h[1]); x = x + ulen(h[1]) + 1
    fg(C.label);  gset(x, H, h[2]); x = x + ulen(h[2]) + 3
  end
end

local function render()
  bg(C.bg); gfill(1, 1, W, H, " ")
  drawHeader()
  drawPower()
  drawStats()
  drawListFrame()
  drawList()
  drawFooter()
end

-- ============================= input handling ===============================

local KEY_ENTER, KEY_BACK, KEY_ESC = 28, 14, 1
local KEY_UP, KEY_DOWN, KEY_PGUP, KEY_PGDN = 200, 208, 201, 209
local KEY_HOME, KEY_END = 199, 207

local function handleFilterKey(char, code)
  if code == KEY_ENTER then
    ui.filterMode = false
  elseif code == KEY_ESC then
    ui.filterMode = false
    ui.filterText = ""
    invalidateView()
  elseif code == KEY_BACK then
    ui.filterText = usub(ui.filterText, 1, math.max(0, ulen(ui.filterText) - 1))
    invalidateView()
  elseif char and char >= 32 and char < 127 then
    ui.filterText = ui.filterText .. string.char(char)
    ui.selected, ui.top = 1, 1
    invalidateView()
  end
end

local function handleCraftKey(char, code)
  if code == KEY_ESC then
    ui.craftMode, ui.craftQty, ui.craftTarget = false, "", nil
    setStatus("craft cancelled", "info")
  elseif code == KEY_BACK then
    ui.craftQty = ui.craftQty:sub(1, -2)
  elseif char and char >= 48 and char <= 57 then
    if #ui.craftQty < 7 then ui.craftQty = ui.craftQty .. string.char(char) end
  elseif code == KEY_ENTER then
    local qty = tonumber(ui.craftQty)
    local target = ui.craftTarget
    ui.craftMode, ui.craftQty, ui.craftTarget = false, "", nil

    if not qty or qty <= 0 then
      setStatus("craft cancelled: quantity must be a positive number", "bad")
      return
    end
    if not target then
      setStatus("craft cancelled: no item selected", "bad")
      return
    end
    if not target.craftEntry then
      setStatus("craft failed: '" .. target.label .. "' is not craftable", "bad")
      return
    end

    local ok, result = requestCraft(target.craftEntry, qty)
    if ok then
      setStatus("craft requested: " .. target.label .. " x" .. comma(qty), "good")
    else
      setStatus("craft failed: " .. tostring(result), "bad")
    end
  end
end

local function handleKey(char, code)
  if ui.filterMode then return handleFilterKey(char, code) end
  if ui.craftMode  then return handleCraftKey(char, code) end

  local ch = (char and char > 0) and string.char(char):lower() or ""
  local list = filteredItems()
  ui.status = nil

  if ch == "q" then
    return "quit"
  elseif ch == "r" then
    -- A manual refresh is deliberate, so rebuild the craftable catalogue too;
    -- that is how a newly-added recipe shows up without restarting.
    state.craftLoadedAt = nil
    refresh()
    setStatus("refreshed", "good")
  elseif ch == "j" or code == KEY_DOWN then
    ui.selected = math.min(#list, ui.selected + 1)
  elseif ch == "k" or code == KEY_UP then
    ui.selected = math.max(1, ui.selected - 1)
  elseif code == KEY_PGDN then
    ui.selected = math.min(#list, ui.selected + visibleRows())
  elseif code == KEY_PGUP then
    ui.selected = math.max(1, ui.selected - visibleRows())
  elseif code == KEY_HOME then
    ui.selected = 1
  elseif code == KEY_END then
    ui.selected = #list
  elseif ch == "/" then
    ui.filterMode = true
    ui.filterText = ""
    invalidateView()
  elseif ch == "s" then
    ui.sort = (ui.sort % #SORTS) + 1
    ui.selected, ui.top = 1, 1
    invalidateView()
    setStatus("sorted by " .. SORTS[ui.sort].label, "info")
  elseif code == KEY_ESC then
    ui.filterText = ""
    ui.selected, ui.top = 1, 1
    invalidateView()
  elseif ch == "c" then
    local it = list[ui.selected]
    if not it then
      setStatus("nothing selected", "bad")
    elseif not it.craftEntry then
      -- Refuse up front rather than after prompting for a quantity.
      setStatus("'" .. it.label .. "' is not craftable in this network", "bad")
    else
      ui.craftMode, ui.craftQty, ui.craftTarget = true, "", it
    end
  end
end

-- ================================ main loop =================================

local function setup()
  origW, origH = safeCall(gpuAddr, "getResolution")
  local mw, mh = safeCall(gpuAddr, "maxResolution")
  if mw and mh then safeCall(gpuAddr, "setResolution", mw, mh) end
  W, H = safeCall(gpuAddr, "getResolution")
  W, H = W or 80, H or 25
end

local function teardown()
  bg(0x000000); fg(0xFFFFFF)
  if origW and origH then safeCall(gpuAddr, "setResolution", origW, origH) end
  term.clear()
  term.setCursor(1, 1)
end

-- Building the craftable catalogue costs one bridge call per entry, so show
-- progress instead of appearing to hang on a large network.
local function craftProgress(done, total)
  bg(C.bg); gfill(1, math.floor(H / 2), W, 1, " ")
  fg(C.accent)
  local msg = string.format("Loading craftable catalogue…  %d / %d", done, total)
  gset(math.max(1, math.floor((W - ulen(msg)) / 2)), math.floor(H / 2), msg)
end

local function main()
  setup()
  bg(C.bg); gfill(1, 1, W, H, " ")
  loadCraftables(craftProgress)
  refresh()
  render()

  local lastRefresh = computer.uptime()
  while true do
    local e, _, char, code = event.pull(3, "key_down")
    if e == "key_down" then
      if handleKey(char, code) == "quit" then break end
    end

    if computer.uptime() - lastRefresh >= 3 then
      -- Recipes change far more slowly than stock levels, so the expensive
      -- catalogue rebuild runs on its own much longer interval.
      if not state.craftLoadedAt
         or computer.uptime() - state.craftLoadedAt >= CRAFT_RELOAD_SECONDS then
        loadCraftables()
      end
      refresh()
      lastRefresh = computer.uptime()
    end

    render()
  end

  teardown()
end

local ok, err = pcall(main)
if not ok then
  teardown()
  print("factory.lua crashed: " .. tostring(err))
end
