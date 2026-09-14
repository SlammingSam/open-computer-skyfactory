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

local component     = require("component")
local event          = require("event")
local serialization  = require("serialization")
local text           = serialization -- alias: text.serialize / text.unserialize

-- ==== CONFIG ====================================================
local PORT = 123 -- network port all proxy traffic uses

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

-- Performs the actual HTTP request via the Internet Card and returns a
-- response table { status, statusText, headers, body }.
-- Raises a Lua error (caller should pcall this) on any failure.
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

    -- Read the full response body, chunk by chunk. Errors thrown while
    -- reading (e.g. connection reset, DNS failure) surface here.
    local chunks = {}
    while true do
        local ok, chunk = pcall(function() return handle.read(8192) end)
        if not ok then
            pcall(function() handle.close() end)
            error(chunk) -- re-raise the read error
        end
        if chunk == nil then
            break -- end of stream
        end
        chunks[#chunks + 1] = chunk
    end

    -- Pull status code / headers if the internet card exposes them
    -- (available on modern OpenComputers internet card implementations).
    local status, statusText, respHeaders = 200, "OK", {}
    if handle.response then
        local ok, code, msg, hdrs = pcall(handle.response)
        if ok and code then
            status = code
            statusText = msg or ""
            respHeaders = hdrs or {}
        end
    end

    pcall(function() handle.close() end)

    return {
        status = status,
        statusText = statusText,
        headers = respHeaders,
        body = table.concat(chunks),
    }
end

-- Sends a serialized message back to a client.
local function sendTo(address, msgType, payload)
    local ok, err = pcall(network.send, address, PORT, msgType, text.serialize(payload))
    if not ok then
        print("[proxy] ERROR sending reply to " .. tostring(address) .. ": " .. tostring(err))
    end
end

-- ==== MAIN LOOP ==================================================
-- Waits for incoming "modem_message" events (aka net_msg) and handles them.
while true do
    local name, localAddr, remoteAddr, port, distance, msgType, payload =
        event.pull("modem_message")

    if name == "modem_message" and port == PORT and msgType == "request" then

        if not isAllowed(remoteAddr) then
            print("[proxy] Rejected request from unauthorized address: " .. tostring(remoteAddr))
            sendTo(remoteAddr, "response", { error = "unauthorized: address not on allowlist" })

        else
            local ok, req = pcall(text.unserialize, payload)

            if not ok or type(req) ~= "table" or type(req.url) ~= "string" then
                print("[proxy] Malformed request from " .. tostring(remoteAddr))
                sendTo(remoteAddr, "response", { id = req and req.id, error = "malformed request" })

            else
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
                    print("[proxy]   -> " .. tostring(result.status) .. " " .. tostring(result.statusText))
                else
                    print("[proxy]   -> ERROR: " .. tostring(result))
                    sendTo(remoteAddr, "response", { id = req.id, error = tostring(result) })
                end
            end
        end
    end
    -- any other message types / ports are silently ignored
end
