-- http.lua
-- OpenComputers HTTP Client (talks to proxy.lua over the Network Card)
--
-- Requires only a Network Card - no Internet Card needed on this computer.
-- All real HTTP work happens on the proxy computer; this just sends it a
-- request description and waits for the reply.
--
-- Usage:
--   local http = require("http") -- or dofile("http.lua") depending on setup
--   local body, err = http.get("https://example.com")
--   local body, err = http.post("https://example.com/api", "some=data", {["Content-Type"]="application/x-www-form-urlencoded"})
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
-- Set this to the proxy computer's modem address (printed on proxy startup,
-- or run `address` on the proxy machine).
local PROXY_ADDRESS = "PUT-PROXY-MODEM-ADDRESS-HERE"
local PORT = 123      -- must match PORT in proxy.lua
local TIMEOUT = 30    -- seconds to wait for a response before giving up

network.open(PORT)

local http = {}

-- ==== REQUEST ID ================================================
-- Used to match responses to the request that triggered them, in case
-- multiple requests are in flight or stray messages show up.
local nextId = 0
local function newId()
    nextId = nextId + 1
    return tostring(os.time()) .. "-" .. tostring(nextId)
end

-- ==== CORE SEND/WAIT LOGIC ======================================
-- Sends a request table to the proxy and blocks (with timeout) until the
-- matching response arrives. Returns the decoded response table, or
-- nil + error string on failure/timeout.
local function sendRequest(reqTable)
    if PROXY_ADDRESS == "PUT-PROXY-MODEM-ADDRESS-HERE" then
        return nil, "PROXY_ADDRESS not configured - edit the top of http.lua"
    end

    reqTable.id = newId()

    local ok, err = pcall(network.send, PROXY_ADDRESS, PORT, "request", text.serialize(reqTable))
    if not ok then
        return nil, "failed to send request: " .. tostring(err)
    end

    local startTime = os.clock()
    while true do
        local elapsed = os.clock() - startTime
        local remaining = TIMEOUT - elapsed
        if remaining <= 0 then
            return nil, "request timed out after " .. TIMEOUT .. "s"
        end

        local name, _, fromAddr, fromPort, _, msgType, payload =
            event.pull(remaining, "modem_message")

        if name == nil then
            return nil, "request timed out after " .. TIMEOUT .. "s"
        end

        if fromAddr == PROXY_ADDRESS and fromPort == PORT and msgType == "response" then
            local okDecode, data = pcall(text.unserialize, payload)
            if okDecode and type(data) == "table" and data.id == reqTable.id then
                return data
            end
            -- else: not JSON/serialized correctly, or belongs to a
            -- different request - keep waiting
        end
        -- any other modem_message traffic is ignored and we loop again
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
