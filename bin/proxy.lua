-- proxy.lua
-- OpenComputers Internet Proxy Server
--
-- Requires: an Internet Card AND a Network Card (modem) installed on this
-- computer. Other computers on the network (with only a Network Card) send
-- it HTTP requests, it fetches them via the Internet Card, and sends the
-- result back.
--
-- NOTE: OpenComputers' network hardware is the "modem" component and fires
-- "modem_message" events. There's no built-in "network" library or
-- "net_msg" event, and "text" has no serialize/unserialize (that lives in
-- "serialization"). We alias those here so the rest of the code reads the
-- way the spec describes, while still using real OC APIs underneath.
--
-- Pair this with the matching http.lua. They share a wire format and an old
-- copy of either will only handle small messages.
--
-- WHY THIS IS NOT THE ORIGINAL
--
-- 1. CHUNKING. A modem drops any message over 8192 bytes, and a rack relays
--    packets with a per-tick budget and a bounded queue, so even a legal
--    message can be dropped in transit when it arrives in a burst. Requests
--    are tiny and always land; replies are not, which is why small pages
--    worked and a 4 KB API response silently never arrived. Replies are now
--    split across numbered chunks and reassembled, with a pause between each
--    so a rack relay can drain.
--
-- 2. internet.request() is ASYNCHRONOUS. It returns a handle before the
--    connection has been established, and reading too early returns nil,
--    which is indistinguishable from end-of-stream. Fixed by waiting on
--    finishConnect() first.
--
-- 3. Requests are queued by an event LISTENER, not pulled in the main loop.
--    Anything that sleeps while serving a request calls event.pull
--    underneath, and OpenComputers DISCARDS events a pull does not match, so
--    a request arriving mid-fetch would silently vanish. A listener still
--    fires during those sleeps.
--
-- 4. Reading never discards data it already has. A read timeout returns the
--    partial body rather than erroring, and a run of empty reads after data
--    has started ends the body instead of stalling for the full timeout.

local component     = require("component")
local event          = require("event")
local serialization  = require("serialization")
local text           = serialization -- alias: text.serialize / text.unserialize

-- ==== CONFIG ====================================================
local PORT = 123 -- network port all proxy traffic uses

-- Seconds to wait for a connection to be established.
local CONNECT_TIMEOUT = 10
-- Overall ceiling on reading one response.
local READ_TIMEOUT = 25
-- Once data has started arriving, how long a run of empty reads means "the
-- body is finished". OpenComputers returns nil at a true end of stream, but
-- not every server gets there promptly, and stalling READ_TIMEOUT on every
-- request is far worse than ending a completed body slightly early.
local EMPTY_GRACE = 2

-- Wire limits. A modem drops anything over 8192 bytes outright; the smaller
-- payload size leaves room for the other arguments and keeps each packet well
-- inside what a rack relay will forward.
local MAX_MESSAGE = 8192
local CHUNK_BYTES = 4096
-- Pause between chunks. A rack forwards a limited number of packets per tick
-- and drops what overflows its queue, so firing a burst loses the tail.
local CHUNK_DELAY = 0.05

-- Allowlist of permitted client (modem) addresses.
-- Add entries like this (get the address by running `address` on the
-- client, or printing component.modem.address there):
--   ["3ab12c45-6789-40ab-9e12-abcdef123456"] = true,
-- If this table is left EMPTY, all clients are allowed (handy for testing,
-- but insecure - lock it down before leaving the proxy running unattended).
local ALLOWLIST = {
    -- ["3ab12c45-6789-40ab-9e12-abcdef123456"] = true,
}

-- ==== SETUP ======================================================
assert(component.isAvailable("internet"), "This computer needs an Internet Card")
assert(component.isAvailable("modem"), "This computer needs a Network Card")

local internet = component.internet
local network  = component.modem -- alias: modem == "network card"

network.open(PORT)

print("[proxy] Internet proxy started.")
print("[proxy] My address: " .. network.address)
print("[proxy] Listening on port " .. PORT)
if next(ALLOWLIST) == nil then
    print("[proxy] WARNING: allowlist is empty - accepting requests from ANY address")
end

-- ==== HELPERS ====================================================

local function isAllowed(address)
    if next(ALLOWLIST) == nil then
        return true -- empty allowlist = allow everyone
    end
    return ALLOWLIST[address] == true
end

-- Status codes arrive as floats over this bridge, so a bare tostring prints
-- "200.0". Show whole numbers as whole numbers.
local function fmtStatus(s)
    local n = tonumber(s)
    if n and n == math.floor(n) then return string.format("%d", n) end
    return tostring(s)
end

-- ==== CHUNKED TRANSPORT ==========================================
-- Small messages go out exactly as the original sent them, so an old client
-- still works for anything that fits. Anything larger is split into numbered
-- chunks the matching http.lua reassembles.

local nextChunkId = 0
local function newChunkId()
    nextChunkId = nextChunkId + 1
    return network.address:sub(1, 8) .. "-" .. tostring(nextChunkId)
end

local function sendSerialized(address, kind, serialized)
    if #serialized <= CHUNK_BYTES then
        local ok, err = pcall(network.send, address, PORT, kind, serialized)
        if not ok then
            print("[proxy] ERROR sending reply to " .. tostring(address) .. ": " .. tostring(err))
        end
        return
    end

    local id = newChunkId()
    local total = math.ceil(#serialized / CHUNK_BYTES)
    print(string.format("[proxy]   .. %d bytes, sending as %d chunks", #serialized, total))

    for i = 1, total do
        local part = serialized:sub((i - 1) * CHUNK_BYTES + 1, i * CHUNK_BYTES)
        local ok, err = pcall(network.send, address, PORT, "chunk", kind, id, i, total, part)
        if not ok then
            print("[proxy] ERROR sending chunk " .. i .. "/" .. total .. ": " .. tostring(err))
            return
        end
        -- Let the relay drain rather than overflowing its queue.
        if i < total then os.sleep(CHUNK_DELAY) end
    end
end

-- Sends a reply, shrinking it first if it is implausibly large. Response
-- headers are rarely what the caller wants and on API responses can outweigh
-- the body, so they are the first thing dropped.
local ABSURD_REPLY = MAX_MESSAGE * 8

local function sendTo(address, msgType, payload)
    local serialized = text.serialize(payload)

    if #serialized > ABSURD_REPLY and type(payload) == "table" and payload.headers then
        local slim = {}
        for k, v in pairs(payload) do slim[k] = v end
        slim.headers = nil
        local reslim = text.serialize(slim)
        if #reslim < #serialized then
            print(string.format("[proxy]   .. %d bytes with headers, %d without - dropped them",
                                #serialized, #reslim))
            serialized = reslim
        end
    end

    sendSerialized(address, msgType, serialized)
end

-- Reassembles inbound chunks. Returns a complete payload string when the last
-- piece of a set arrives, nil otherwise.
local inbound = {}

local function collectChunk(remoteAddr, kind, id, seq, total, data)
    if kind ~= "request" then return nil end
    seq, total = math.floor(tonumber(seq) or 0), math.floor(tonumber(total) or 0)
    if seq < 1 or total < 1 then return nil end

    local key = tostring(remoteAddr) .. "|" .. tostring(id)
    local slot = inbound[key]
    if not slot then
        slot = { total = total, got = 0, parts = {}, at = os.clock() }
        inbound[key] = slot
    end
    if not slot.parts[seq] then
        slot.parts[seq] = data
        slot.got = slot.got + 1
    end
    slot.at = os.clock()

    if slot.got >= slot.total then
        inbound[key] = nil
        return table.concat(slot.parts)
    end

    -- Drop half-finished sets from clients that gave up, so they cannot pile up.
    for k, v in pairs(inbound) do
        if os.clock() - v.at > 60 then inbound[k] = nil end
    end
    return nil
end

-- ==== HTTP =======================================================

-- Waits for the request to actually connect. finishConnect() returns true when
-- connected, false while still working, and nil + message on failure. Returns
-- false if it never gave a definite answer, in which case we read anyway --
-- that is what the original did, and it worked for most hosts.
local function waitForConnection(handle)
    if type(handle.finishConnect) == "nil" then
        return true
    end
    local deadline = os.clock() + CONNECT_TIMEOUT
    while os.clock() < deadline do
        local ok, err = handle.finishConnect()
        if ok == true then return true end
        if ok == nil then
            error("could not connect: " .. tostring(err or "unknown error"))
        end
        os.sleep(0.05)
    end
    return false
end

-- Performs the actual HTTP request and returns { status, statusText, headers,
-- body }. Raises only when nothing at all was retrieved; a partial body is
-- returned rather than thrown away.
local function doHttpRequest(method, url, headers, body)
    if type(url) ~= "string" or url == "" then
        error("missing or invalid url")
    end
    method = method or "GET"

    local postData = nil
    if method == "POST" then
        postData = body or ""
    end

    local handle = internet.request(url, postData, headers)
    if not handle then
        error("failed to open connection to " .. url)
    end

    local okConnect, connected = pcall(waitForConnection, handle)
    if not okConnect then
        pcall(function() handle.close() end)
        error(connected)
    end

    local chunks, total = {}, 0
    local hardDeadline = os.clock() + READ_TIMEOUT
    local emptyUntil = nil
    local timedOut = false

    while true do
        local ok, chunk = pcall(function() return handle.read(8192) end)

        if not ok then
            if total > 0 then break end
            pcall(function() handle.close() end)
            error(chunk)
        end

        if chunk == nil then
            break
        elseif chunk == "" then
            emptyUntil = emptyUntil or (os.clock() + (total > 0 and EMPTY_GRACE or READ_TIMEOUT))
            if os.clock() > emptyUntil or os.clock() > hardDeadline then
                timedOut = (total == 0)
                break
            end
            os.sleep(0.05)
        else
            chunks[#chunks + 1] = chunk
            total = total + #chunk
            emptyUntil = nil
            if os.clock() > hardDeadline then break end
            os.sleep(0)
        end
    end

    if timedOut then
        pcall(function() handle.close() end)
        error("no data after " .. READ_TIMEOUT .. "s")
    end

    local status, statusText, respHeaders = 200, "OK", {}
    local statusKnown = false
    if handle.response then
        local ok, code, msg, hdrs = pcall(handle.response)
        if ok and code then
            status = code
            statusText = msg or ""
            respHeaders = hdrs or {}
            statusKnown = true
        end
    end

    pcall(function() handle.close() end)

    return {
        status = status,
        statusText = statusText,
        statusKnown = statusKnown, -- false means the 200 above is a guess
        headers = respHeaders,
        body = table.concat(chunks),
    }
end

-- Handles one queued request end to end.
local function handleRequest(remoteAddr, payload)
    if not isAllowed(remoteAddr) then
        print("[proxy] Rejected request from unauthorized address: " .. tostring(remoteAddr))
        sendTo(remoteAddr, "response", { error = "unauthorized: address not on allowlist" })
        return
    end

    local ok, req = pcall(text.unserialize, payload)
    if not ok or type(req) ~= "table" or type(req.url) ~= "string" then
        print("[proxy] Malformed request from " .. tostring(remoteAddr))
        sendTo(remoteAddr, "response", { id = req and req.id, error = "malformed request" })
        return
    end

    print(string.format(
        "[proxy] %s %s  (from %s)",
        tostring(req.method or "GET"),
        tostring(req.url),
        tostring(remoteAddr)
    ))

    local okReq, result = pcall(doHttpRequest, req.method, req.url, req.headers, req.body)

    if okReq then
        result.id = req.id
        print(string.format("[proxy]   -> %s %s, %d bytes%s",
            fmtStatus(result.status),
            tostring(result.statusText),
            #result.body,
            result.statusKnown and "" or "  (status not reported by the card - assumed)"))
        sendTo(remoteAddr, "response", result)
    else
        print("[proxy]   -> ERROR: " .. tostring(result))
        sendTo(remoteAddr, "response", { id = req.id, error = tostring(result) })
    end
end

-- ==== MAIN LOOP ==================================================
-- Requests are captured by a listener rather than pulled here directly. Any
-- os.sleep() during a fetch calls event.pull underneath, and OpenComputers
-- throws away events that the pull does not match -- so pulling here would
-- silently lose every request that arrived while another was being served, and
-- every chunk of a chunked one.

local pending = {}

event.listen("modem_message", function(_, _, remoteAddr, port, _, msgType, a, b, c, d, e)
    if port ~= PORT then return end

    if msgType == "request" then
        pending[#pending + 1] = { from = remoteAddr, payload = a }

    elseif msgType == "chunk" then
        local complete = collectChunk(remoteAddr, a, b, c, d, e)
        if complete then
            pending[#pending + 1] = { from = remoteAddr, payload = complete }
        end

    elseif msgType == "discover" then
        -- Lets a client find this proxy without anyone typing an address.
        pcall(network.send, remoteAddr, PORT, "proxy_here")
    end
end)

while true do
    if #pending > 0 then
        local item = table.remove(pending, 1)
        local ok, err = pcall(handleRequest, item.from, item.payload)
        if not ok then
            -- One bad request must never take the whole proxy down with it.
            print("[proxy] ERROR handling request: " .. tostring(err))
        end
    else
        os.sleep(0.1)
    end
end
