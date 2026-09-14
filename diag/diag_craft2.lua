-- diag_craft2.lua — READ-ONLY diagnostic for AE2 auto-crafting calling
-- convention on this bridge. Does NOT call entry.request() on anything —
-- that would trigger a real craft against the live ME network. It only
-- inspects entry.request's metatable and calls the read-only
-- entry.getItemStack() (a pure lookup, not a craft/consume operation).
--
-- Run with: factory (or `edit diag_craft2.lua` then run), review the
-- printed output, and paste it back before any live crafting code is
-- enabled in factory.lua (CRAFT_CONFIRMED).

local component = require("component")

local function findAddr(ctype)
  for addr in component.list(ctype, true) do
    return addr
  end
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

local craftables, err = safeCall(meAddr, "getCraftables")
if not craftables then
  print("getCraftables failed: " .. tostring(err))
  return
end

print("getCraftables() returned " .. tostring(#craftables) .. " entries.")
print("Inspecting first 5 (read-only — no request() is ever called):")
print(string.rep("-", 60))

local SAMPLE = 5
for i = 1, math.min(SAMPLE, #craftables) do
  local entry = craftables[i]
  print("[" .. i .. "] label=" .. tostring(entry.label or entry.name or "?"))

  -- type() of each callback field
  print("    type(entry.request)      = " .. type(entry.request))
  print("    type(entry.getItemStack) = " .. type(entry.getItemStack))

  -- metatable inspection of entry.request, without calling it
  if type(entry.request) == "table" then
    local mt = getmetatable(entry.request)
    if mt then
      print("    getmetatable(entry.request) found")
      print("      __call present: " .. tostring(mt.__call ~= nil))
      print("      __call type:    " .. type(mt.__call))
    else
      print("    getmetatable(entry.request) = nil (no metatable)")
    end
  end

  -- safe, read-only probe: getItemStack should just report the item,
  -- not craft or consume anything.
  local ok, stack = pcall(function() return entry.getItemStack() end)
  if ok then
    print("    entry.getItemStack() call succeeded, result type=" .. type(stack))
    if type(stack) == "table" then
      for k, v in pairs(stack) do
        print("      ." .. tostring(k) .. " = " .. tostring(v))
      end
    else
      print("      value = " .. tostring(stack))
    end
  else
    print("    entry.getItemStack() call FAILED: " .. tostring(stack))
  end

  print(string.rep("-", 60))
end

print("Diagnostic complete. entry.request() was never invoked.")
print("Paste this full output back before enabling live crafting.")
