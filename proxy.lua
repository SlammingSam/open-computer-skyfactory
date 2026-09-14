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
-- WHY THIS IS NOT THE ORIGINAL
--
-- 1. internet.request() is ASYNCHRONOUS. It returns a handle before the
--    connection has been established, and reading that handle too early
--    returns nil -- indistinguishable from end-of-stream. Fixed by waiting on
--    finishConnect() first.
--
-- 2. Requests are queued by an event LISTENER, not pulled in the main loop.
--    Anything that sleeps while a request is being served calls event.pull
--    underneath, and OpenComputers DISCARDS events a pull does not match --
--    so a request arriving mid-fetch would silently vanish. A registered
--    listener still fires during those sleeps, so nothing is lost.
--
-- 3. Reading never discards data it already has. A read timeout returns the
--    partial body rather than erroring, and a run of empty reads after data
--    has started is treated as the end of the body instead of stalling for
--    the full timeout on every single request.
--
-- 4. Replies that would exceed the modem's 8192-byte message limit are shrunk
--    (headers dropped) or refused with a readable error, instead of being
--    handed to the modem and silently dropped.

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

-- An OpenComputers modem drops any message larger than this.
local MAX_MESSAGE = 8192

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

-- Checks whether a client address is allowed to use this proxy.
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

-- Waits for the request to actually connect.
-- finishConnect() returns true when connected, false while still working, and
-- nil + message on failure. Returns true if connected, false if it never gave
-- a definite answer -- in which case we read anyway, since that is what the
-- original did and it worked for most hosts.
local function waitForConnection(handle)
    if type(handle.finishConnect) == "nil" then
        return true -- older card without the call; nothing to wait on
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

-- Performs the actual HTTP request via the Internet Card and returns a
-- response table { status, statusText, headers, body }.
-- Raises a Lua error (caller should pcall this) only when nothing was
-- retrieved at all; a partial body is returned rather than thrown away.
local function doHttpRequest(method, url, headers, body)
    if type(url) ~= "string" or url == "" then
        error("missing or invalid url")
    end
    method = method or "GET"

    -- internet.request(url, postData, headers)
    -- postData must be nil/omitted for GET requests.
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
        error(connected) -- the message from waitForConnection
    end

    local chunks, total = {}, 0
    local hardDeadline = os.clock() + READ_TIMEOUT
    local emptyUntil = nil
    local timedOut = false

    while true do
        local ok, chunk = pcall(function() return handle.read(8192) end)

        if not ok then
            -- A read error after data has arrived still leaves us with a
            -- usable response; only a total failure is worth raising.
            if total > 0 then break end
            pcall(function() handle.close() end)
            error(chunk)
        end

        if chunk == nil then
            break -- genuine end of stream
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
            if os.clock() > hardDeadline then
                timedOut = false
                break
            end
            os.sleep(0) -- keep the watchdog happy; the listener still queues
        end
    end

    if timedOut then
        pcall(function() handle.close() end)
        error("no data after " .. READ_TIMEOUT .. "s")
    end

    -- Pull status code / headers if the internet card exposes them
    -- (available on modern OpenComputers internet card implementations).
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

-- Sends a serialized message back to a client, keeping it under the modem's
-- message limit. Response headers are usually larger than callers need and on
-- API responses can outweigh the body, so they are the first thing dropped.
local function sendTo(address, msgType, payload)
    local serialized = text.serialize(payload)

    if #serialized > MAX_MESSAGE and type(payload) == "table" and payload.headers then
        local slim = {}
        for k, v in pairs(payload) do slim[k] = v end
        slim.headers = nil
        local reslim = text.serialize(slim)
        if #reslim <= MAX_MESSAGE then
            print(string.format("[proxy]   .. %d bytes with headers, %d without - dropped them",
                                #serialized, #reslim))
            serialized = reslim
        end
    end

    if #serialized > MAX_MESSAGE then
        print(string.format("[proxy]   !! reply is %d bytes, over the %d-byte modem limit",
                            #serialized, MAX_MESSAGE))
        serialized = text.serialize({
            id = payload.id,
            error = string.format(
                "response was %d bytes, over the %d-byte limit one modem message can carry",
                #serialized, MAX_MESSAGE),
        })
    end

    local ok, err = pcall(network.send, address, PORT, msgType, serialized)
    if not ok then
        print("[proxy] ERROR sending reply to " .. tostring(address) .. ": " .. tostring(err))
    end
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
        sendTo(remoteAddr, "response", result)
        -- Body size is the useful half of this line: an empty body with a
        -- "200 OK" is the signature of a request that never really happened,
        -- and it used to be invisible from here.
        print(string.format("[proxy]   -> %s %s, %d bytes%s",
            fmtStatus(result.status),
            tostring(result.statusText),
            #result.body,
            result.statusKnown and "" or "  (status not reported by the card - assumed)"))
    else
        print("[proxy]   -> ERROR: " .. tostring(result))
        sendTo(remoteAddr, "response", { id = req.id, error = tostring(result) })
    end
end

-- ==== MAIN LOOP ==================================================
-- Requests are captured by a listener rather than pulled here directly. Any
-- os.sleep() during a fetch calls event.pull underneath, and OpenComputers
-- throws away events that the pull does not match -- so pulling here would
-- silently lose every request that arrived while another was being served.
-- A registered listener still runs during those sleeps.

local pending = {}

event.listen("modem_message", function(_, _, remoteAddr, port, _, msgType, payload)
    if port == PORT and msgType == "request" then
        pending[#pending + 1] = { from = remoteAddr, payload = payload }
    end
    -- any other message types / ports are silently ignored
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
