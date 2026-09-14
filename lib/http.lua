-- http.lua
-- OpenComputers HTTP Client (talks to proxy.lua over the Network Card)
--
-- Requires only a Network Card - no Internet Card needed on this computer.
-- All real HTTP work happens on the proxy computer; this just sends it a
-- request description and waits for the reply.
--
-- Usage:
--   local http = dofile("http.lua")
--   local body, err, status, headers = http.get("https://example.com")
--   local body, err = http.post("https://example.com/api", "some=data",
--                               {["Content-Type"]="application/json"})
--   http.setTimeout(180)       -- for slow endpoints, e.g. local LLM inference
--
-- Pair this with the matching proxy.lua. They share a wire format, and an old
-- copy of either will only handle small messages.
--
-- WHY THIS IS NOT THE ORIGINAL
--
-- CHUNKING. A modem drops any message over 8192 bytes, and a rack relays
-- packets with a per-tick budget and a bounded queue, so even a legal message
-- can be dropped in transit when it arrives as a burst. Requests are tiny and
-- always land; replies are not. That asymmetry is why a small page worked
-- while a 4 KB API response silently never arrived, and why the failure looked
-- like a timeout rather than an error. Both directions now split large
-- payloads into numbered chunks and reassemble them.
--
-- NOTE: see proxy.lua for why component.modem is aliased as "network" and
-- the "serialization" library is aliased as "text" here.

local component    = require("component")
local event         = require("event")
local serialization = require("serialization")
local text          = serialization -- alias: text.serialize / text.unserialize

assert(component.isAvailable("modem"), "This computer needs a Network Card")
local network = component.modem -- alias: modem == "network card"

-- ==== CONFIG ====================================================
-- The proxy address is NOT stored in this file. It comes from /home/.env, so
-- that updating this file cannot lose it:
--
--   PROXY_ADDRESS=e66d90a3-8a83-4b8a-930a-2aecdfaefb59
--
-- If it is missing, the client asks the network who the proxy is and writes
-- the answer back to /home/.env, so discovery happens once rather than on
-- every request. Setting it by hand always wins over discovery.

local PORT = 123       -- must match PORT in proxy.lua
local TIMEOUT = 90     -- seconds to wait for a response before giving up
local DISCOVER_TIMEOUT = 3

-- Loads a module from lib/ whether it was installed, cloned, or is sitting in
-- the working directory. env is optional: without it this file still works,
-- it just has to rediscover the proxy each run.
local function loadModule(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  for _, p in ipairs({ "/home/lib/" .. name .. ".lua", "/usr/lib/" .. name .. ".lua",
                       "/lib/" .. name .. ".lua", "lib/" .. name .. ".lua",
                       name .. ".lua" }) do
    local chunk = loadfile(p)
    if chunk then
      local okc, m = pcall(chunk)
      if okc and type(m) == "table" then return m end
    end
  end
  return nil
end

local env = loadModule("env")

-- Must not exceed the proxy's CHUNK_BYTES budget.
local CHUNK_BYTES = 4096
local CHUNK_DELAY = 0.05

network.open(PORT)

local http = {}

-- Local model inference regularly runs past a short timeout, so callers need
-- to be able to raise it without editing this file.
function http.setTimeout(seconds)
  local n = tonumber(seconds)
  if n and n > 0 then TIMEOUT = n end
  return TIMEOUT
end

function http.getTimeout() return TIMEOUT end

-- ==== PROXY DISCOVERY ===========================================

local discovered = nil

-- Asks the network who the proxy is. proxy.lua answers a "discover" broadcast
-- with its own address.
local function discover()
  pcall(network.broadcast, PORT, "discover")
  local deadline = os.clock() + DISCOVER_TIMEOUT
  while os.clock() < deadline do
    local name, _, fromAddr, fromPort, _, msgType =
      event.pull(deadline - os.clock(), "modem_message")
    if name == nil then break end
    if fromPort == PORT and msgType == "proxy_here" then return fromAddr end
  end
  return nil
end

local function proxyAddress()
  if discovered then return discovered end

  -- A hand-set address in /home/.env always wins.
  if env then
    local configured = env.get("PROXY_ADDRESS")
    if configured then
      discovered = configured
      return discovered
    end
  end

  local found = discover()
  if not found then return nil end
  discovered = found

  -- Remember it, so this costs one broadcast ever rather than one per run.
  -- Failing to write is not fatal; discovery simply repeats next time.
  if env then pcall(env.set, "PROXY_ADDRESS", found) end
  return discovered
end

http.proxyAddress = proxyAddress

-- Forgets the cached address so the next request rediscovers. Useful after
-- moving the proxy to a different computer.
function http.forgetProxy()
  discovered = nil
end

-- ==== REQUEST ID ================================================
-- Used to match responses to the request that triggered them, in case
-- multiple requests are in flight or stray messages show up.
local nextId = 0
local function newId()
  nextId = nextId + 1
  return tostring(os.time()) .. "-" .. tostring(nextId)
end

-- ==== CHUNKED TRANSPORT =========================================

local function sendSerialized(address, kind, serialized)
  if #serialized <= CHUNK_BYTES then
    return pcall(network.send, address, PORT, kind, serialized)
  end

  local id = newId()
  local total = math.ceil(#serialized / CHUNK_BYTES)
  for i = 1, total do
    local part = serialized:sub((i - 1) * CHUNK_BYTES + 1, i * CHUNK_BYTES)
    local ok, err = pcall(network.send, address, PORT, "chunk", kind, id, i, total, part)
    if not ok then return false, err end
    -- Let a rack relay drain instead of overflowing its queue.
    if i < total then os.sleep(CHUNK_DELAY) end
  end
  return true
end

-- Reassembles inbound response chunks. Returns a complete payload string when
-- the final piece arrives, nil otherwise.
local inbound = {}

local function collectChunk(kind, id, seq, total, data)
  if kind ~= "response" then return nil end
  seq, total = math.floor(tonumber(seq) or 0), math.floor(tonumber(total) or 0)
  if seq < 1 or total < 1 then return nil end

  local slot = inbound[id]
  if not slot then
    slot = { total = total, got = 0, parts = {} }
    inbound[id] = slot
  end
  if not slot.parts[seq] then
    slot.parts[seq] = data
    slot.got = slot.got + 1
  end

  if slot.got >= slot.total then
    inbound[id] = nil
    return table.concat(slot.parts)
  end
  return nil
end

-- ==== CORE SEND/WAIT LOGIC ======================================
-- Sends a request table to the proxy and blocks (with timeout) until the
-- matching response arrives. Returns the decoded response table, or
-- nil + error string on failure/timeout.
local function sendRequest(reqTable)
  local address = proxyAddress()
  if not address then
    return nil, "no proxy found. Check proxy.lua is running and on the same " ..
                "network, or put its address in /home/.env as:\n" ..
                "  PROXY_ADDRESS=<the address proxy.lua prints on startup>"
  end

  reqTable.id = newId()

  local ok, err = sendSerialized(address, "request", text.serialize(reqTable))
  if not ok then
    return nil, "failed to send request: " .. tostring(err)
  end

  local startTime = os.clock()
  while true do
    local remaining = TIMEOUT - (os.clock() - startTime)
    if remaining <= 0 then
      return nil, "request timed out after " .. TIMEOUT .. "s"
    end

    local name, _, fromAddr, fromPort, _, msgType, a, b, c, d, e =
      event.pull(remaining, "modem_message")

    if name == nil then
      return nil, "request timed out after " .. TIMEOUT .. "s"
    end

    if fromAddr == address and fromPort == PORT then
      local payload = nil
      if msgType == "response" then
        payload = a
      elseif msgType == "chunk" then
        payload = collectChunk(a, b, c, d, e)
      end

      if payload then
        local okDecode, data = pcall(text.unserialize, payload)
        if okDecode and type(data) == "table" and data.id == reqTable.id then
          return data
        end
        -- Not ours, or not decodable - keep waiting for one that is.
      end
    end
  end
end

-- ==== PUBLIC API =================================================

-- http.get(url, headers)
-- Returns: body, err, status, headers
function http.get(url, headers)
  local resp, err = sendRequest({
    method = "GET",
    url = url,
    headers = headers or {},
  })
  if not resp then
    return nil, err
  end
  if resp.error then
    return nil, resp.error
  end
  return resp.body, nil, resp.status, resp.headers
end

-- http.post(url, body, headers)
-- Returns: body, err, status, headers
function http.post(url, body, headers)
  local resp, err = sendRequest({
    method = "POST",
    url = url,
    body = body or "",
    headers = headers or {},
  })
  if not resp then
    return nil, err
  end
  if resp.error then
    return nil, resp.error
  end
  return resp.body, nil, resp.status, resp.headers
end

return http
