-- claude.lua
-- Ask Claude questions from an OpenComputers terminal, routed through
-- proxy.lua / http.lua (this computer needs ONLY a Network Card - the
-- Internet Card lives on the proxy machine).
--
-- This version gives Claude TOOL ACCESS to this computer, similar to
-- Claude Code: it can read files, write files, list directories, and run
-- shell commands, deciding for itself when to use them to answer you.
--
-- WARNING: run_command and write_file can modify or delete things on this
-- computer. Both require a [y/N] confirmation before running. read_file
-- and list_files run automatically since they can't change anything.
--
-- Run one-shot:      claude "list the files in /home and summarize them"
-- Run interactively: claude            (then type questions, "exit" to quit)

local http = dofile("http.lua") -- reuses PROXY_ADDRESS / PORT / TIMEOUT from http.lua

local okFs, filesystem = pcall(require, "filesystem")
if not okFs then filesystem = nil end

-- ==== CONFIG =====================================================
-- API key is loaded from a .env file rather than hardcoded here, so this
-- script can be shared/edited without leaking the key. The .env file
-- should sit at ENV_PATH and contain a line like:
--   ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxx
-- Blank lines and lines starting with # are ignored.
local ENV_PATH = "/home/.env"
local API_URL = "https://api.anthropic.com/v1/messages"
local ANTHROPIC_VERSION = "2023-06-01"

-- The "worst" (cheapest/smallest) current Claude model.
local MODEL = "claude-haiku-4-5-20251001"
local MAX_TOKENS = 800

-- Safety cap on how many tool-use round trips a single question can take
-- before we give up and return an error, so a confused agent loop can't
-- run forever (or rack up API calls) on the slow in-game network.
local MAX_TOOL_ITERATIONS = 8

-- Tool output longer than this gets truncated before being sent back to
-- Claude, to keep messages small over the network.
local MAX_TOOL_OUTPUT_CHARS = 4000

-- Optional system prompt - leave "" to omit it entirely.
local SYSTEM_PROMPT = "You are a terminal assistant running on an OpenComputers "
    .. "computer in Minecraft. You have tools to read/write files, list "
    .. "directories, and run shell commands on THIS machine - use them when "
    .. "they'd help answer the question. Keep replies short and in plain "
    .. "text (no markdown headers or formatting), since this is shown on an "
    .. "in-game terminal screen."

-- ==== .env LOADER =================================================
-- Reads a simple KEY=VALUE .env file into a table. No quoting/escaping
-- support beyond stripping surrounding "..." or '...' if present.
local function loadEnv(path)
    local f, openErr = io.open(path, "r")
    if not f then
        return nil, "couldn't open " .. path .. ": " .. tostring(openErr)
    end

    local env = {}
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "") -- trim
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
            if key then
                value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
                env[key] = value
            end
        end
    end
    f:close()
    return env
end

local API_KEY = nil
do
    local env, err = loadEnv(ENV_PATH)
    if not env then
        print("[claude] WARNING: " .. err)
    else
        API_KEY = env.ANTHROPIC_API_KEY
        if not API_KEY then
            print("[claude] WARNING: ANTHROPIC_API_KEY not found in " .. ENV_PATH)
        end
    end
end

-- ==== MINIMAL JSON LIBRARY ========================================
-- Stock OpenComputers has no JSON library, and tool calling needs real
-- nested JSON (objects/arrays of arbitrary shape), so this is a small
-- general-purpose encoder/decoder rather than the old field-by-field
-- string scanning. Limitations: \u escapes above 127 decode to "?"
-- (no UTF-16 surrogate pair handling) - fine for our purposes.
local json = {}

local emptyObjectMeta = {} -- marks a table as "always encode as {}"
function json.object(t)
    return setmetatable(t or {}, emptyObjectMeta)
end

local escapeMap = {
    ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n',
    ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}
local function jsonEscape(s)
    return (s:gsub('[%c\\"]', function(c)
        return escapeMap[c] or string.format('\\u%04x', c:byte())
    end))
end

local function isJsonArray(t)
    if getmetatable(t) == emptyObjectMeta then return false, 0 end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false, 0 end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false, 0 end
    end
    return true, n
end

function json.encode(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" or t == "number" then
        return tostring(v)
    elseif t == "string" then
        return '"' .. jsonEscape(v) .. '"'
    elseif t == "table" then
        local isArr, n = isJsonArray(v)
        if isArr then
            if n == 0 then return "[]" end
            local parts = {}
            for i = 1, n do parts[i] = json.encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. json.encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        error("json.encode: cannot encode a " .. t)
    end
end

local decodeValue, decodeObject, decodeArray, decodeString

local function skipWs(s, i)
    local _, e = s:find("^%s*", i)
    return e + 1
end

decodeString = function(s, i)
    i = i + 1 -- skip opening quote
    local startI = i
    local buf = {}
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string at " .. i) end
        if c == '"' then
            buf[#buf + 1] = s:sub(startI, i - 1)
            return table.concat(buf), i + 1
        elseif c == "\\" then
            buf[#buf + 1] = s:sub(startI, i - 1)
            local esc = s:sub(i + 1, i + 1)
            if esc == "n" then buf[#buf + 1] = "\n"; i = i + 2
            elseif esc == "t" then buf[#buf + 1] = "\t"; i = i + 2
            elseif esc == "r" then buf[#buf + 1] = "\r"; i = i + 2
            elseif esc == "b" then buf[#buf + 1] = "\b"; i = i + 2
            elseif esc == "f" then buf[#buf + 1] = "\f"; i = i + 2
            elseif esc == '"' then buf[#buf + 1] = '"'; i = i + 2
            elseif esc == "\\" then buf[#buf + 1] = "\\"; i = i + 2
            elseif esc == "/" then buf[#buf + 1] = "/"; i = i + 2
            elseif esc == "u" then
                local code = tonumber(s:sub(i + 2, i + 5), 16) or 63
                buf[#buf + 1] = (code < 128) and string.char(code) or "?"
                i = i + 6
            else
                buf[#buf + 1] = esc; i = i + 2
            end
            startI = i
        else
            i = i + 1
        end
    end
end

local function decodeNumber(s, i)
    local j, n = i, #s
    if s:sub(j, j) == "-" then j = j + 1 end
    while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
    if s:sub(j, j) == "." then
        j = j + 1
        while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
    end
    if s:sub(j, j) == "e" or s:sub(j, j) == "E" then
        j = j + 1
        if s:sub(j, j) == "+" or s:sub(j, j) == "-" then j = j + 1 end
        while j <= n and s:sub(j, j):match("%d") do j = j + 1 end
    end
    return tonumber(s:sub(i, j - 1)), j
end

decodeObject = function(s, i)
    i = i + 1 -- skip '{'
    local obj = json.object({})
    i = skipWs(s, i)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        i = skipWs(s, i)
        local key
        key, i = decodeString(s, i)
        i = skipWs(s, i)
        if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
        i = skipWs(s, i + 1)
        local val
        val, i = decodeValue(s, i)
        obj[key] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = i + 1
        elseif c == "}" then
            return obj, i + 1
        else
            error("expected ',' or '}' at " .. i)
        end
    end
end

decodeArray = function(s, i)
    i = i + 1 -- skip '['
    local arr, n = {}, 0
    i = skipWs(s, i)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        i = skipWs(s, i)
        local val
        val, i = decodeValue(s, i)
        n = n + 1
        arr[n] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = i + 1
        elseif c == "]" then
            return arr, i + 1
        else
            error("expected ',' or ']' at " .. i)
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decodeString(s, i)
    elseif c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
    elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
    elseif c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4
    elseif c == "-" or c:match("%d") then return decodeNumber(s, i)
    else error("unexpected character '" .. c .. "' at " .. i) end
end

function json.decode(s)
    local ok, val = pcall(function()
        local v = decodeValue(s, 1)
        return v
    end)
    if not ok then return nil, tostring(val) end
    return val
end

-- ==== TOOL IMPLEMENTATIONS ========================================
-- Each tool takes a decoded JSON `input` table and returns a plain Lua
-- result table. Tools should never raise for expected failure modes
-- (missing file, bad path) - return {error=...} instead so Claude sees a
-- normal tool result rather than the whole turn failing.

local function toolReadFile(input)
    local path = input.path
    if not path then return { error = "missing 'path'" } end
    local f, err = io.open(path, "r")
    if not f then return { error = "couldn't open file: " .. tostring(err) } end
    local content = f:read("*a") or ""
    f:close()
    if #content > MAX_TOOL_OUTPUT_CHARS then
        content = content:sub(1, MAX_TOOL_OUTPUT_CHARS) .. "\n...[truncated]"
    end
    return { content = content }
end

local function toolWriteFile(input)
    local path = input.path
    if not path then return { error = "missing 'path'" } end
    local mode = input.append and "a" or "w"
    local f, err = io.open(path, mode)
    if not f then return { error = "couldn't open file: " .. tostring(err) } end
    f:write(input.content or "")
    f:close()
    return { success = true, bytesWritten = #(input.content or "") }
end

local function toolListFiles(input)
    local path = input.path or "."
    if not filesystem then
        return { error = "filesystem library not available on this system" }
    end
    local ok, entries = pcall(function()
        local list = {}
        for name in filesystem.list(path) do
            list[#list + 1] = name
        end
        return list
    end)
    if not ok then return { error = tostring(entries) } end
    return { entries = entries }
end

local function toolRunCommand(input)
    local cmd = input.command
    if not cmd then return { error = "missing 'command'" } end
    if type(io.popen) ~= "function" then
        return { error = "command execution isn't supported on this system (no io.popen)" }
    end
    local ok, handle = pcall(io.popen, cmd)
    if not ok or not handle then
        return { error = "failed to run command: " .. tostring(handle) }
    end
    local output = handle:read("*a") or ""
    handle:close()
    if #output > MAX_TOOL_OUTPUT_CHARS then
        output = output:sub(1, MAX_TOOL_OUTPUT_CHARS) .. "\n...[truncated]"
    end
    return { output = output }
end

-- Tool definitions sent to the API (name/description/JSON-schema input).
local TOOLS = {
    {
        name = "read_file",
        description = "Read the full text contents of a file on this computer.",
        input_schema = {
            type = "object",
            properties = {
                path = { type = "string", description = "Path to the file to read" },
            },
            required = { "path" },
        },
    },
    {
        name = "write_file",
        description = "Write (or append) text content to a file on this computer, creating it if it doesn't exist.",
        input_schema = {
            type = "object",
            properties = {
                path = { type = "string", description = "Path to the file to write" },
                content = { type = "string", description = "Text content to write" },
                append = { type = "boolean", description = "If true, append instead of overwriting" },
            },
            required = { "path", "content" },
        },
    },
    {
        name = "list_files",
        description = "List files and directories at a given path on this computer.",
        input_schema = {
            type = "object",
            properties = {
                path = { type = "string", description = "Directory to list (default '.')" },
            },
        },
    },
    {
        name = "run_command",
        description = "Run a shell command on this computer and return its output.",
        input_schema = {
            type = "object",
            properties = {
                command = { type = "string", description = "Shell command to execute" },
            },
            required = { "command" },
        },
    },
}

local TOOL_IMPL = {
    read_file = toolReadFile,
    write_file = toolWriteFile,
    list_files = toolListFiles,
    run_command = toolRunCommand,
}

-- Tools that can change something on the computer require a manual
-- confirmation before running, same spirit as Claude Code's permission
-- prompts. read_file / list_files are read-only and run automatically.
local NEEDS_CONFIRMATION = { write_file = true, run_command = true }

local function confirmToolUse(name, input)
    io.write(string.format("[claude] wants to run %s(%s) - allow? [y/N] ", name, json.encode(input)))
    local answer = io.read()
    return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

-- Turns a tool result table into short readable text for Claude to read.
local function resultToText(result)
    if result.error then return "Error: " .. tostring(result.error)
    elseif result.content ~= nil then return tostring(result.content)
    elseif result.entries ~= nil then return table.concat(result.entries, "\n")
    elseif result.output ~= nil then return tostring(result.output)
    elseif result.success then
        return "OK" .. (result.bytesWritten and (" (" .. result.bytesWritten .. " bytes written)") or "")
    else
        return json.encode(result)
    end
end

-- ==== CORE ASK FUNCTION ==========================================
local claude = {}

local function buildRequestBody(history)
    local body = {
        model = MODEL,
        max_tokens = MAX_TOKENS,
        messages = history,
        tools = TOOLS,
    }
    if SYSTEM_PROMPT ~= "" then
        body.system = SYSTEM_PROMPT
    end
    return json.encode(body)
end

-- claude.ask(history) -> replyText, err
-- `history` is a list of {role=, content=} message tables ending in the
-- newest "user" message. Runs the full tool-use loop (calling the API,
-- executing any requested tools, sending results back) until Claude gives
-- a final text answer or MAX_TOOL_ITERATIONS is hit. `history` is mutated
-- in place with every turn so the conversation can continue naturally.
function claude.ask(history)
    if not API_KEY then
        return nil, "no API key loaded - check ANTHROPIC_API_KEY is set in " .. ENV_PATH
    end

    local headers = {
        ["x-api-key"] = API_KEY,
        ["anthropic-version"] = ANTHROPIC_VERSION,
        ["content-type"] = "application/json",
    }

    for iteration = 1, MAX_TOOL_ITERATIONS do
        local requestBody = buildRequestBody(history)
        local respBody, err, status = http.post(API_URL, requestBody, headers)
        if not respBody then
            return nil, "proxy/network error: " .. tostring(err)
        end

        local data, decodeErr = json.decode(respBody)
        if not data then
            return nil, "couldn't parse response: " .. tostring(decodeErr)
        end

        if status and status ~= 200 then
            local apiErr = data.error and data.error.message
            return nil, "API error (" .. tostring(status) .. "): " .. (apiErr or respBody)
        end

        history[#history + 1] = { role = "assistant", content = data.content }

        if data.stop_reason == "tool_use" then
            local resultBlocks = {}
            for _, block in ipairs(data.content) do
                if block.type == "tool_use" then
                    local input = block.input or json.object({})
                    print(string.format("[claude] tool: %s(%s)", block.name, json.encode(input)))

                    local result
                    local impl = TOOL_IMPL[block.name]
                    if not impl then
                        result = { error = "unknown tool: " .. tostring(block.name) }
                    elseif NEEDS_CONFIRMATION[block.name] and not confirmToolUse(block.name, input) then
                        result = { error = "user denied permission for this tool call" }
                    else
                        local ok, res = pcall(impl, input)
                        result = ok and res or { error = tostring(res) }
                    end

                    resultBlocks[#resultBlocks + 1] = {
                        type = "tool_result",
                        tool_use_id = block.id,
                        content = resultToText(result),
                        is_error = result.error ~= nil or nil,
                    }
                end
            end
            history[#history + 1] = { role = "user", content = resultBlocks }
            -- loop again so Claude can see the tool results
        else
            local textParts = {}
            for _, block in ipairs(data.content) do
                if block.type == "text" then
                    textParts[#textParts + 1] = block.text
                end
            end
            return table.concat(textParts, "\n")
        end
    end

    return nil, "stopped after " .. MAX_TOOL_ITERATIONS .. " tool-use round trips without a final answer"
end

-- ==== CLI ENTRY POINT =============================================
local function runOneShot(question)
    local history = { { role = "user", content = question } }
    print("[claude] thinking...")
    local answer, err = claude.ask(history)
    if not answer then
        print("[claude] Error: " .. err)
    else
        print("")
        print(answer)
        print("")
    end
end

local function runInteractive()
    print("[claude] Interactive chat with " .. MODEL .. " (tool access enabled). Type 'exit' to quit.")
    print("[claude] WARNING: this assistant can read, write, and run commands on this computer.")
    local history = {}
    while true do
        io.write("> ")
        local line = io.read()
        if not line or line == "exit" or line == "quit" then
            break
        end
        if line ~= "" then
            local beforeLen = #history
            history[#history + 1] = { role = "user", content = line }
            print("[claude] thinking...")
            local answer, err = claude.ask(history)
            if not answer then
                print("[claude] Error: " .. err)
                -- roll back to before this turn; note this can't perfectly
                -- undo a partially-completed tool-use round trip, but keeps
                -- the next request from being sent with an inconsistent
                -- (would-be-rejected) message history.
                for i = #history, beforeLen + 1, -1 do
                    history[i] = nil
                end
            else
                print("")
                print(answer)
                print("")
            end
        end
    end
end

local args = { ... }
if #args > 0 then
    runOneShot(table.concat(args, " "))
else
    runInteractive()
end

return claude
