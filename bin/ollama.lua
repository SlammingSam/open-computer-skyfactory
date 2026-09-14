-- ollama.lua — chat with a local Ollama model from an OpenComputers terminal,
-- with tool access to this computer (read/write files, list dirs, search, run
-- commands) in the spirit of Claude Code.
--
-- Network path:  this computer (Network Card only)
--                  -> modem -> proxy.lua (Internet Card)
--                  -> http://<your PC>:11434/api/chat
-- Every byte goes through http.lua, exactly like claude.lua does. Nothing here
-- talks to an Internet Card directly.
--
-- Run one-shot:      ollama "summarise every .lua file in /home"
-- Run interactively: ollama                (full-screen chat UI, touch enabled)
-- Skip confirmations: ollama -u            (see UNSAFE MODE below)
--
-- See OLLAMA.md for setup (proxy address, Ollama host, model pull, timeout).

local component = require("component")
local event     = require("event")
local computer  = require("computer")
local term      = require("term")

local uni; pcall(function() uni = require("unicode") end)
local ulen = uni and uni.len or string.len
local usub = uni and uni.sub or string.sub

local okFs, filesystem = pcall(require, "filesystem")
if not okFs then filesystem = nil end
local okShell, shell = pcall(require, "shell")
if not okShell then shell = nil end

-- ================================= config ===================================

-- Where Ollama listens, as seen FROM THE PROXY COMPUTER's Internet Card — that
-- request is made by the Minecraft server's JVM, so this is the server host's
-- view of the network. If Ollama runs on the same box as the MC server,
-- 127.0.0.1 is correct; otherwise use that machine's LAN IP.
local OLLAMA_HOST = "http://127.0.0.1:11434"

-- Default model. qwen2.5:7b-instruct is the pick for a 1070 Ti (8 GB): Q4_K_M
-- weights are ~4.7 GB, leaving room for the KV cache at NUM_CTX below, and it
-- has first-class tool-calling support in Ollama plus strong instruction
-- following for its size. Change with /model, or edit this line.
local MODEL = "qwen2.5:7b-instruct"

-- Context window. Ollama's own default is small (2k-4k depending on version),
-- which a system prompt + tool schemas + one file read will blow straight
-- through. 8192 costs well under a gigabyte of KV cache at this size.
local NUM_CTX = 8192

-- Cap on a single reply. Mostly a guard against the model rambling past
-- http.lua's request timeout — see TIMEOUT in http.lua and OLLAMA.md.
local NUM_PREDICT = 600

-- Low on purpose. This is an agent reporting facts it was handed, not a
-- writing assistant: at 0.6 a 7B model will cheerfully report "none was found"
-- while holding the answer, because the phrase was in the question. Raise it
-- with OLLAMA_TEMPERATURE if you want more variety and care less about that.
local TEMPERATURE = 0.3

-- Keeps the model resident in VRAM between messages, so only the first request
-- after a cold start pays the load cost.
local KEEP_ALIVE = "30m"

-- Safety cap on tool-use round trips per question, so a confused loop can't
-- run forever on the slow in-game network.
local MAX_TOOL_ITERATIONS = 10

-- Hard ceiling on one outgoing request, in bytes, or nil for no transport
-- limit. This only applies to an http.lua/proxy.lua pair that sends each
-- request as a SINGLE modem message, where OpenComputers' 8192-byte cap
-- applies to the whole payload. A chunking pair splits the request instead, so
-- the ceiling is lifted at startup when http.chunked is set.
--
-- Leaving this at a small value with a chunking transport is actively harmful:
-- it squeezes HISTORY_CHAR_BUDGET below what a multi-step task needs, and the
-- model starts forgetting what it was asked.
local MAX_REQUEST_BYTES = 7600

-- Tool output longer than this is truncated before being sent back to the
-- model. Kept well under MAX_REQUEST_BYTES so that a single file read cannot
-- fill an entire request on its own.
local MAX_TOOL_OUTPUT_CHARS = 1800

-- Conversation trimming budget, in characters: whichever of the context window
-- and the transport limit binds first. The tool schemas and system prompt cost
-- roughly 2,400 bytes of every request before any conversation is added.
local HISTORY_CHAR_BUDGET = NUM_CTX * 3 - 4000
if MAX_REQUEST_BYTES then
  HISTORY_CHAR_BUDGET = math.min(HISTORY_CHAR_BUDGET, MAX_REQUEST_BYTES - 2400)
end

local SYSTEM_PROMPT =
  "You are a terminal assistant running on an OpenComputers computer inside " ..
  "Minecraft. You have tools that act on THIS machine: read_file, write_file, " ..
  "delete_file, list_files, search_files and run_command. Use them whenever a " ..
  "question is about files, directories or the state of this computer — do " ..
  "not guess at file contents you have not read.\n\n" ..
  "Work one step at a time: call a tool, look at the result, then decide the " ..
  "next step. Prefer list_files or search_files to locate something before " ..
  "reading it.\n\n" ..
  "run_command runs OpenOS SHELL commands — ls, cat, cp, mv, mkdir, rm — not " ..
  "Lua code. Passing a Lua expression makes the shell look for a program by " ..
  "that name and fail. To delete something use delete_file.\n\n" ..
  "Check results before reporting success. If a tool says FAILED or returns " ..
  "an error, say what went wrong; do not assume the job is done. Verify a " ..
  "deletion or a write with list_files when it matters.\n\n" ..
  "Report what the tools actually returned. Quote the real output rather than " ..
  "describing what you expected, and never reuse a phrase from the question " ..
  "as if it were a result — if the question said \"or say none was found\" and " ..
  "the tool returned an address, the answer is that address.\n\n" ..
  "If output does not look like an answer to the question — an address, a " ..
  "number, a list — then something is wrong with the code or the command, and " ..
  "repeating it unchanged will not help.\n\n" ..
  "Before writing code that calls a library on this machine, read that " ..
  "library with read_file and use the functions it actually defines, rather " ..
  "than guessing names.\n\n" ..
  "NEVER fake a library to make code run. If require fails, or a function is " ..
  "missing, say so and stop. Do not define a stub, do not hardcode a value, " ..
  "do not invent what the real one would have returned. A program that prints " ..
  "a made-up answer is far worse than one that does not run, because it looks " ..
  "like it worked.\n\n" ..
  "When a program fails, fix the actual cause. A nil global usually means the " ..
  "require line is missing, not that the library is broken.\n\n" ..
  "Answer in plain text only. No markdown headers, bold, or bullet syntax — " ..
  "output is shown on a low-resolution in-game screen. Keep replies short."

-- ============================== module loading ==============================
-- Everything shared lives in lib/. Modules are loaded by name so this file
-- does not care whether the toolchain was installed to /home/lib, cloned
-- somewhere else, or is sitting in the working directory. require() is tried
-- first, so a normal OpenOS install just works; the explicit paths are the
-- fallback for a copy run straight out of a clone.

local function scriptDir()
  local ok, info = pcall(function() return debug.getinfo(1, "S") end)
  if not ok or not info or type(info.source) ~= "string" then return nil end
  if info.source:sub(1, 1) ~= "@" then return nil end
  return info.source:sub(2):match("^(.*)/[^/]*$")
end

local function loadModule(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod, "require(" .. name .. ")" end

  local candidates, seen, tried = {}, {}, {}
  local function add(p)
    if p and not seen[p] then seen[p] = true; candidates[#candidates + 1] = p end
  end

  local dir = scriptDir()
  if dir then
    add(dir .. "/../lib/" .. name .. ".lua")  -- installed as bin/ beside lib/
    add(dir .. "/" .. name .. ".lua")
  end
  add("/home/lib/" .. name .. ".lua")
  add("/usr/lib/" .. name .. ".lua")
  add("/lib/" .. name .. ".lua")
  add("lib/" .. name .. ".lua")
  add(name .. ".lua")

  for _, p in ipairs(candidates) do
    local chunk = loadfile(p)
    if chunk then
      local okc, m = pcall(chunk)
      if okc and type(m) == "table" then return m, p end
      tried[#tried + 1] = p .. " (" .. tostring(m):sub(1, 50) .. ")"
    else
      tried[#tried + 1] = p .. " (not found)"
    end
  end
  return nil, table.concat(tried, "\n  ")
end

local json, jsonPath = loadModule("json")
if not json then
  print("ollama.lua: could not load lib/json.lua. Looked in:\n  " .. tostring(jsonPath))
  print("\nRun the updater (update.lua) to install the library files, or copy")
  print("lib/json.lua to /home/lib/json.lua.")
  return
end

local http, httpPath = loadModule("http")
if not http then
  print("ollama.lua: could not load lib/http.lua. Looked in:\n  " .. tostring(httpPath))
  print("\nCopy lib/http.lua to /home/lib/http.lua, and put PROXY_ADDRESS in")
  print("/home/.env (or let it discover the proxy automatically).")
  return
end

-- Optional: without it the defaults above are simply used as written.
local env = loadModule("env")

-- Machine-specific settings live in /home/.env so an update never overwrites
-- them, and so a second computer can point at a different host or model
-- without editing this file.
if env then
  OLLAMA_HOST = (env.get("OLLAMA_HOST", OLLAMA_HOST)):gsub("/+$", "")
  MODEL       = env.get("OLLAMA_MODEL", MODEL)
  NUM_CTX     = env.number("OLLAMA_NUM_CTX", NUM_CTX)
  NUM_PREDICT = env.number("OLLAMA_NUM_PREDICT", NUM_PREDICT)
  TEMPERATURE = env.number("OLLAMA_TEMPERATURE", TEMPERATURE)
  MAX_TOOL_ITERATIONS = env.number("OLLAMA_MAX_STEPS", MAX_TOOL_ITERATIONS)

  -- Derived from NUM_CTX, so it has to be recomputed after any override.
  HISTORY_CHAR_BUDGET = NUM_CTX * 3 - 4000
  if MAX_REQUEST_BYTES then
    HISTORY_CHAR_BUDGET = math.min(HISTORY_CHAR_BUDGET, MAX_REQUEST_BYTES - 2400)
  end
end

-- Local model inference regularly runs past http.lua's default timeout,
-- especially on the first (cold) request while the model loads into VRAM.
if type(http.setTimeout) == "function" then
  pcall(http.setTimeout, env and env.number("HTTP_TIMEOUT", 180) or 180)
end

-- A chunking transport splits a large request across modem messages, so the
-- 8192-byte cap no longer applies to the payload as a whole and the context
-- window becomes the only real limit. Without this the history budget collapses
-- to about 5,000 characters, which is roughly three tool results — not enough
-- to hold the task and the work, so multi-step jobs stall partway.
if http.chunked then
  MAX_REQUEST_BYTES = nil
end

HISTORY_CHAR_BUDGET = NUM_CTX * 3 - 4000
if MAX_REQUEST_BYTES then
  HISTORY_CHAR_BUDGET = math.min(HISTORY_CHAR_BUDGET, MAX_REQUEST_BYTES - 2400)
end

-- ============================== Ollama client ===============================
-- Ollama speaks OpenAI-shaped tool calls, not Anthropic-shaped ones: tools are
-- {type="function", function={name, description, parameters}} and results come
-- back as message.tool_calls rather than content blocks. That difference is
-- the main reason this is a separate file from claude.lua rather than a flag.

local JSON_HEADERS = { ["Content-Type"] = "application/json" }

local lastStats = nil   -- token counts from the most recent reply, for the UI
local lastPayload = nil -- the most recent request body, for /last

-- Turns http.lua's error strings into something that names the actual fix.
local function explainNetworkError(err)
  err = tostring(err or "unknown error")
  if err:find("timed out") then
    return err .. "\nThe model is probably still generating. Raise TIMEOUT in " ..
           "http.lua (30 -> 180), or lower NUM_PREDICT here."
  end
  if err:find("PROXY_ADDRESS not configured") then
    return err .. "\nSet it to the modem address proxy.lua prints on startup."
  end
  if err:find("too big") or err:find("8192") then
    return err .. "\nOne modem message caps at 8192 bytes. Lower " ..
           "MAX_REQUEST_BYTES in ollama.lua, or use an http.lua/proxy.lua " ..
           "pair that chunks large messages."
  end
  if err:find("connect") or err:find("refused") or err:find("denied") then
    return err .. "\nCheck Ollama is running and reachable at " .. OLLAMA_HOST ..
           " from the machine hosting the Minecraft server, and that OpenComputers'" ..
           " internet blacklist is not blocking that address."
  end
  return err
end

-- An empty body is NOT a parsing problem, and reporting it as one sends you
-- looking in the wrong place. OpenComputers' Internet Card does not expose the
-- body of an error response, and proxy.lua falls back to "200 OK" when
-- handle.response() tells it nothing — so a refused or blocked connection
-- arrives here as a successful, completely empty reply. Say so plainly.
local function emptyBodyError(status)
  local hostOnly = OLLAMA_HOST:match("^https?://([^/]+)") or OLLAMA_HOST
  return "empty reply from " .. OLLAMA_HOST .. " (reported as HTTP " ..
    tostring(status or "?") .. ").\n" ..
    "1. Almost always: OpenComputers is blocking " .. hostOnly .. ". It ships " ..
    "with loopback and private addresses blacklisted, and the card does not " ..
    "surface the refusal -- no body and no status, which proxy.lua then " ..
    "reports as a guessed 200 OK. Stop the server, edit config/" ..
    "opencomputers.cfg, and delete the loopback entries (127.0.0.0/8, " ..
    "localhost) from blacklist in the internet block.\n" ..
    "2. Confirm it by running nettest.lua on the proxy computer. A blocked " ..
    "address prints: finishConnect -> nil, address is blacklisted\n" ..
    "3. On the machine hosting the Minecraft server, check Ollama itself:  " ..
    "curl " .. OLLAMA_HOST .. "/api/tags\n" ..
    "4. Make sure proxy.lua on the proxy computer is this repo's version."
end

local function decodeBody(respBody, status)
  if type(respBody) ~= "string" or not respBody:match("%S") then
    return nil, emptyBodyError(status)
  end
  local data, decodeErr = json.decode(respBody)
  if type(data) ~= "table" then
    return nil, "could not parse Ollama's reply: " .. tostring(decodeErr) ..
                "\nraw: " .. respBody:sub(1, 200)
  end
  if data.error then
    return nil, "Ollama: " .. tostring(data.error)
  end
  if status and status ~= 200 then
    return nil, "Ollama returned HTTP " .. tostring(status) .. ": " .. respBody:sub(1, 200)
  end
  return data
end

local function postPayload(path, payload)
  local respBody, err, status = http.post(OLLAMA_HOST .. path, payload, JSON_HEADERS)
  if not respBody then
    return nil, explainNetworkError(err)
  end
  return decodeBody(respBody, status)
end

-- POST a JSON body and decode the reply. Returns table, nil on success.
local function postJson(path, bodyTable)
  return postPayload(path, json.encode(bodyTable))
end

local function getJson(path)
  local respBody, err, status = http.get(OLLAMA_HOST .. path)
  if not respBody then return nil, explainNetworkError(err) end
  return decodeBody(respBody, status)
end

-- Raw probe behind /diag: reports exactly what came back rather than trying to
-- make sense of it, so a broken chain can be located without guessing.
local function probeRaw(path)
  local respBody, err, status = http.get(OLLAMA_HOST .. path)
  if not respBody then
    return "GET " .. OLLAMA_HOST .. path .. "\n  failed: " .. tostring(err)
  end
  local preview = respBody:sub(1, 120):gsub("[\r\n]", " ")
  return "GET " .. OLLAMA_HOST .. path ..
    "\n  status: " .. tostring(status or "(none reported)") ..
    "\n  body:   " .. #respBody .. " bytes" ..
    (#respBody > 0 and ("\n  starts: " .. preview) or "  <- empty")
end

-- Lists installed models. Doubles as the startup reachability check, since it
-- is the cheapest endpoint that proves the whole chain works.
local function listModels()
  local data, err = getJson("/api/tags")
  if not data then return nil, err end
  local names = {}
  for _, m in ipairs(data.models or {}) do
    if type(m) == "table" and m.name then names[#names + 1] = m.name end
  end
  table.sort(names)
  return names
end

-- Drops the oldest droppable message, keeping the system prompt at index 1 and
-- never leaving a tool result without the assistant turn that requested it —
-- Ollama rejects that outright. Returns false when there is nothing left to
-- give up.
local function dropOldestMessage(messages)
  if #messages <= 2 then return false end
  table.remove(messages, 2)
  while #messages > 2 and messages[2].role == "tool" do
    table.remove(messages, 2)
  end
  return true
end

-- Sends one chat turn. `messages` is the full history array, trimmed in place
-- if the encoded request will not fit through the modem.
local function ollamaChat(messages, tools)
  local function buildBody()
    local body = {
      model = MODEL,
      messages = messages,
      -- Non-negotiable: streaming replies are newline-delimited JSON, and
      -- proxy.lua hands back the whole concatenated body, which is not valid
      -- JSON as a single document.
      stream = false,
      keep_alive = KEEP_ALIVE,
      options = json.object({
        num_ctx = NUM_CTX,
        num_predict = NUM_PREDICT,
        temperature = TEMPERATURE,
      }),
    }
    if tools and #tools > 0 then body.tools = tools end
    return json.encode(body)
  end

  -- Measure the real encoded request rather than estimating from character
  -- counts. Estimating is what let an oversized request reach the modem in the
  -- first place; this cannot be wrong about its own payload.
  local payload = buildBody()
  while MAX_REQUEST_BYTES and #payload > MAX_REQUEST_BYTES do
    if not dropOldestMessage(messages) then
      return nil, "this request is " .. #payload .. " bytes, over the " ..
        MAX_REQUEST_BYTES .. "-byte limit one modem message can carry, and " ..
        "there is nothing older left to drop.\nShorten the question, or raise " ..
        "MAX_REQUEST_BYTES if your http.lua and proxy.lua chunk large messages."
    end
    payload = buildBody()
  end

  lastPayload = payload
  local data, err = postPayload("/api/chat", payload)
  if not data then return nil, err end
  if type(data.message) ~= "table" then
    return nil, "Ollama replied without a message field"
  end

  lastStats = {
    promptTokens = tonumber(data.prompt_eval_count) or 0,
    replyTokens  = tonumber(data.eval_count) or 0,
    seconds      = (tonumber(data.total_duration) or 0) / 1e9,
    -- "length" means the reply was cut off at num_predict rather than the
    -- model choosing to stop, which is what a half-finished answer looks like.
    doneReason   = data.done_reason,
  }
  return data.message
end

-- Warms the model into VRAM so the first real question does not also pay the
-- load cost (which is what usually blows past http.lua's timeout).
local function warmModel()
  return postJson("/api/chat", {
    model = MODEL,
    messages = {},          -- no messages = load only, generate nothing
    stream = false,
    keep_alive = KEEP_ALIVE,
    options = json.object({ num_ctx = NUM_CTX }),
  })
end

-- ================================== tools ===================================
-- Each tool takes a decoded arguments table and returns a plain Lua result
-- table. Tools never raise for expected failures (missing file, bad path) —
-- they return {error=...} so the model sees a normal tool result and can
-- recover, rather than the whole turn dying.

-- io.open resolves relative paths against the shell's working directory, but
-- filesystem.* does not — it silently treats them as relative to root. Every
-- filesystem.* call below therefore goes through here first. (Same bug that
-- made git.lua fail to write a single file until it was fixed the same way.)
local function resolvePath(p)
  p = tostring(p or "")
  if p == "" then p = "." end
  if p:sub(1, 1) ~= "/" then
    local cwd = "/"
    if shell and shell.getWorkingDirectory then
      cwd = shell.getWorkingDirectory() or "/"
    end
    if cwd == "/" then cwd = "" end
    p = cwd .. "/" .. p
  end
  if filesystem and filesystem.canonical then
    local ok, c = pcall(filesystem.canonical, p)
    if ok and type(c) == "string" then p = c end
  end
  if p == "" then p = "/" end
  return p
end

local function truncate(s, limit)
  limit = limit or MAX_TOOL_OUTPUT_CHARS
  if #s > limit then
    return s:sub(1, limit) .. "\n...[truncated, " .. (#s - limit) .. " more characters]"
  end
  return s
end

-- OpenComputers kills a program that runs too long without yielding. Anything
-- that loops over files calls this so a big directory tree cannot trip it.
local function pacer()
  local last = os.clock()
  return function()
    if os.clock() - last > 0.8 then
      os.sleep(0)
      last = os.clock()
    end
  end
end

local function toolReadFile(input)
  local path = input.path
  if type(path) ~= "string" or path == "" then return { error = "missing path" } end
  local f, err = io.open(path, "r")
  if not f then return { error = "couldn't open file: " .. tostring(err) } end
  local content = f:read("*a") or ""
  f:close()

  -- Optional windowing, so the model can page through a file bigger than the
  -- output cap instead of only ever seeing its first few thousand characters.
  local from = tonumber(input.start_line)
  local count = tonumber(input.line_count)
  if from or count then
    local lines, n = {}, 0
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      n = n + 1
      lines[n] = line
    end
    from = math.max(1, math.floor(from or 1))
    local to = count and math.min(n, from + math.floor(count) - 1) or n
    local slice = {}
    for i = from, to do slice[#slice + 1] = string.format("%5d  %s", i, lines[i] or "") end
    content = table.concat(slice, "\n")
    return { content = truncate(content), note = string.format("lines %d-%d of %d", from, to, n) }
  end

  return { content = truncate(content) }
end

local function toolWriteFile(input)
  local path = input.path
  if type(path) ~= "string" or path == "" then return { error = "missing path" } end
  local content = input.content
  if content == nil then return { error = "missing content" } end
  content = tostring(content)

  -- Create the parent directory rather than failing on a path one level deep.
  if filesystem then
    local abs = resolvePath(path)
    local dir = abs:match("^(.*)/[^/]*$")
    if dir and dir ~= "" and not filesystem.exists(dir) then
      pcall(filesystem.makeDirectory, dir)
    end
  end

  -- Whether this replaces something matters: a model that has just failed to
  -- run a program will sometimes overwrite it with a stub that returns a
  -- hardcoded value, and saying so makes that visible instead of silent.
  --
  -- Probed with io.open rather than filesystem.exists so the path resolves
  -- exactly the way the write below resolves it. The two disagree on relative
  -- paths, and checking one while writing the other is how a replacement would
  -- go unreported.
  local replaced = nil
  if not input.append then
    local probe = io.open(path, "r")
    if probe then
      local ok, size = pcall(function() return probe:seek("end") end)
      if not ok or type(size) ~= "number" then
        local pok, existing = pcall(function() return probe:read("*a") end)
        size = (pok and existing) and #existing or 0
      end
      probe:close()
      replaced = size
    end
  end

  local mode = input.append and "a" or "w"
  local f, err = io.open(path, mode)
  if not f then return { error = "couldn't open file: " .. tostring(err) } end
  f:write(content)
  f:close()
  return { success = true, bytesWritten = #content, replaced = replaced }
end

-- Without this the model improvises deletion through run_command, usually as a
-- Lua expression like os.remove("x") -- which the OpenOS shell treats as the
-- name of a program to run, fails to find, and reports as "file not found".
-- That reads exactly like "the file is already gone", so the model concludes
-- the job is done while the file is still sitting there.
local function toolDeleteFile(input)
  if not filesystem then return { error = "filesystem library not available" } end
  local path = input.path
  if type(path) ~= "string" or path == "" then return { error = "missing path" } end

  local abs = resolvePath(path)
  if not filesystem.exists(abs) then
    return { error = "nothing to delete: " .. abs .. " does not exist" }
  end
  if filesystem.isDirectory(abs) and not input.recursive then
    return { error = abs .. " is a directory. Pass recursive=true to delete it " ..
                     "and everything inside it." }
  end

  local ok, err = pcall(filesystem.remove, abs)
  if not ok then return { error = "could not delete " .. abs .. ": " .. tostring(err) } end
  if filesystem.exists(abs) then
    return { error = "delete reported success but " .. abs .. " is still there" }
  end
  return { success = true, deleted = abs }
end

local function toolListFiles(input)
  if not filesystem then return { error = "filesystem library not available" } end
  local path = resolvePath(input.path or ".")
  if not filesystem.exists(path) then return { error = "no such path: " .. path } end
  if not filesystem.isDirectory(path) then
    return { error = path .. " is a file, not a directory" }
  end

  local ok, entries = pcall(function()
    local list, yield = {}, pacer()
    for name in filesystem.list(path) do
      local full = path .. (path:sub(-1) == "/" and "" or "/") .. name
      local size = filesystem.size(full)
      list[#list + 1] = (name:sub(-1) == "/") and name
        or string.format("%s  (%d bytes)", name, size or 0)
      yield()
    end
    table.sort(list)
    return list
  end)
  if not ok then return { error = tostring(entries) } end
  if #entries == 0 then return { content = "(empty directory)" } end
  return { entries = entries }
end

-- Plain-substring search across a directory tree. OpenOS has no grep, and
-- "find where this is defined" is the single most useful thing a coding
-- assistant does, so it gets a real tool rather than being faked through
-- run_command.
local SEARCH_MAX_FILES = 300
local SEARCH_MAX_HITS = 60
local SEARCH_MAX_FILE_BYTES = 200000

local function toolSearchFiles(input)
  if not filesystem then return { error = "filesystem library not available" } end
  local needle = input.pattern
  if type(needle) ~= "string" or needle == "" then return { error = "missing pattern" } end
  local root = resolvePath(input.path or ".")
  if not filesystem.exists(root) then return { error = "no such path: " .. root } end

  local extFilter = input.extension
  if type(extFilter) == "string" and extFilter ~= "" then
    extFilter = extFilter:gsub("^%.", ""):lower()
  else
    extFilter = nil
  end

  local lowNeedle = needle:lower()
  local hits, scanned, truncated = {}, 0, false
  local yield = pacer()

  local function scanFile(full, rel)
    local size = filesystem.size(full)
    if size and size > SEARCH_MAX_FILE_BYTES then return end
    local f = io.open(full, "r")
    if not f then return end
    local lineNo = 0
    for line in f:lines() do
      lineNo = lineNo + 1
      if line:lower():find(lowNeedle, 1, true) then
        hits[#hits + 1] = string.format("%s:%d: %s", rel, lineNo, line:sub(1, 160))
        if #hits >= SEARCH_MAX_HITS then truncated = true; break end
      end
      yield()
    end
    f:close()
  end

  local function walk(dir, rel)
    if scanned >= SEARCH_MAX_FILES or truncated then return end
    local ok, iter = pcall(filesystem.list, dir)
    if not ok or not iter then return end
    for name in iter do
      if scanned >= SEARCH_MAX_FILES or truncated then return end
      local full = dir .. (dir:sub(-1) == "/" and "" or "/") .. name
      local childRel = (rel == "" and name or rel .. "/" .. name)
      if name:sub(-1) == "/" then
        walk(full:sub(1, -2), childRel:sub(1, -2))
      else
        local ext = name:match("%.([%w]+)$")
        if not extFilter or (ext and ext:lower() == extFilter) then
          scanned = scanned + 1
          scanFile(full, childRel)
        end
      end
      yield()
    end
  end

  if filesystem.isDirectory(root) then
    walk(root, "")
  else
    scanned = 1
    scanFile(root, root)
  end

  if #hits == 0 then
    return { content = string.format("no matches for [%s] in %s (%d files searched)",
                                     needle, root, scanned) }
  end
  local note = string.format("%d match%s across %d files searched",
                             #hits, #hits == 1 and "" or "es", scanned)
  if truncated then note = note .. " — stopped at the result limit" end
  return { entries = hits, note = note }
end

-- OpenComputers has no io.popen, so a command's output is captured by letting
-- the shell redirect it to a file and reading that back. Redirecting is also
-- what keeps command output from scribbling over the chat UI.
local CMD_OUT = "/tmp/.ollama_cmd_out"
local CMD_ERR = "/tmp/.ollama_cmd_err"

local function readAndRemove(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  if filesystem then pcall(filesystem.remove, path) end
  return s
end

local function toolRunCommand(input)
  local cmd = input.command
  if type(cmd) ~= "string" or cmd == "" then return { error = "missing command" } end
  if not shell or type(shell.execute) ~= "function" then
    return { error = "shell library not available on this system" }
  end

  if filesystem then
    pcall(filesystem.remove, CMD_OUT)
    pcall(filesystem.remove, CMD_ERR)
  end

  local ok, res = pcall(shell.execute, cmd .. " > " .. CMD_OUT .. " 2> " .. CMD_ERR)
  if not ok then
    -- Not every OpenOS build parses the 2> redirect. Fall back to capturing
    -- stdout alone rather than reporting a failure the command never had.
    ok, res = pcall(shell.execute, cmd .. " > " .. CMD_OUT)
  end
  if not ok then
    return { error = "failed to run command: " .. tostring(res) }
  end

  local out = readAndRemove(CMD_OUT)
  local errOut = readAndRemove(CMD_ERR)
  local combined = out
  if errOut ~= "" then
    combined = combined .. (combined ~= "" and "\n" or "") .. "[stderr] " .. errOut
  end
  if combined == "" then
    combined = "(no output)"
  end

  -- Say outright that it failed. Leaving the model to infer it from stderr is
  -- how "file not found" got read as "the file is already gone" -- the shell
  -- was reporting that it could not find a PROGRAM by that name.
  if res == false then
    combined = "The command FAILED (the shell returned an error).\n" .. combined
  end

  return { output = truncate(combined), failed = (res == false) or nil }
end

-- Tool definitions in Ollama's OpenAI-compatible shape. Note this is NOT the
-- Anthropic shape claude.lua uses: the schema key is "parameters", not
-- "input_schema", and each tool is wrapped in a {type="function"} envelope.
local TOOLS = {
  {
    type = "function",
    ["function"] = {
      name = "read_file",
      description = "Read the text contents of a file on this computer. Optionally read only a range of lines.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Path to the file" },
          start_line = { type = "integer", description = "First line to read, 1-based. Omit to read the whole file." },
          line_count = { type = "integer", description = "How many lines to read starting at start_line." },
        },
        required = { "path" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "write_file",
      description = "Write or append text to a file on this computer, creating it and its parent directory if needed.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Path to the file to write" },
          content = { type = "string", description = "Text to write" },
          append = { type = "boolean", description = "Append instead of overwriting" },
        },
        required = { "path", "content" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "list_files",
      description = "List the files and directories at a path on this computer.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Directory to list. Defaults to the working directory." },
        },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "search_files",
      description = "Search a directory tree for files containing a piece of text. Returns matching lines with file names and line numbers.",
      parameters = {
        type = "object",
        properties = {
          pattern = { type = "string", description = "Text to look for. Case-insensitive and literal, not a regex." },
          path = { type = "string", description = "Directory to search. Defaults to the working directory." },
          extension = { type = "string", description = "Only search files with this extension, for example lua" },
        },
        required = { "pattern" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "delete_file",
      description = "Delete a file or directory on this computer. Use this rather than trying to delete through run_command.",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Path to delete" },
          recursive = { type = "boolean", description = "Required to delete a directory and its contents" },
        },
        required = { "path" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "run_command",
      description = "Run an OpenOS SHELL command (ls, cat, cp, mv, mkdir, rm, edit) and return its output. This is a shell, not a Lua interpreter: passing Lua such as os.remove(\"x\") makes the shell look for a program with that name and fail.",
      parameters = {
        type = "object",
        properties = {
          command = { type = "string", description = "Shell command line to execute" },
        },
        required = { "command" },
      },
    },
  },
}

local TOOL_IMPL = {
  read_file    = toolReadFile,
  write_file   = toolWriteFile,
  delete_file  = toolDeleteFile,
  list_files   = toolListFiles,
  search_files = toolSearchFiles,
  run_command  = toolRunCommand,
}

-- Tools that can change this computer ask first. read_file, list_files and
-- search_files cannot change anything, so they run unattended.
local NEEDS_CONFIRMATION = { write_file = true, delete_file = true, run_command = true }

local function resultToText(result)
  if result.error then return "Error: " .. tostring(result.error) end
  local body
  if result.content ~= nil then body = tostring(result.content)
  elseif result.entries ~= nil then body = table.concat(result.entries, "\n")
  elseif result.output ~= nil then body = tostring(result.output)
  elseif result.success then
    body = "OK"
    if result.bytesWritten then
      body = body .. " (" .. result.bytesWritten .. " bytes written"
      if result.replaced then
        body = body .. ", REPLACING an existing " .. result.replaced .. "-byte file"
      end
      body = body .. ")"
    end
    if result.deleted then body = body .. " (deleted " .. result.deleted .. ")" end
  else
    body = json.encode(result)
  end
  if result.note then body = body .. "\n(" .. result.note .. ")" end
  return body
end

-- Ollama hands back tool-call arguments as a decoded object, but some models
-- and some older builds emit a JSON string instead. Accept either.
local function normaliseArgs(raw)
  if type(raw) == "table" then return raw end
  if type(raw) == "string" then
    local decoded = json.decode(raw)
    if type(decoded) == "table" then return decoded end
  end
  return json.object({})
end

-- ================================ agent loop ================================
-- Front-end agnostic: the caller supplies callbacks, so the same loop drives
-- both the full-screen chat UI and the one-shot command line.

-- Skips every confirmation prompt. Off by default; turned on with -u on the
-- command line or /unsafe in the chat.
local UNSAFE = false

-- Keeps the conversation inside NUM_CTX. Messages are dropped oldest-first,
-- never the system prompt at index 1 — and never a tool result without the
-- assistant turn that requested it, which Ollama rejects outright.
local function historySize(history)
  local n = 0
  for _, m in ipairs(history) do
    if type(m.content) == "string" then n = n + #m.content end
    if m.tool_calls then n = n + #json.encode(m.tool_calls) end
    n = n + 80 -- per-message role/framing overhead
  end
  return n
end

-- Where the job currently being worked on was stated. Everything after it is
-- the work itself, so on a multi-step task this is the single most important
-- message in the history — dropping it is what makes a model forget what it
-- was asked and stop halfway through.
local function taskIndex(history)
  for i = #history, 2, -1 do
    if history[i].role == "user" then return i end
  end
  return nil
end

-- Keeps the conversation inside the budget, in order of preference:
--   1. whole earlier turns, from the front
--   2. the oldest completed step of the current task
--   3. nothing else — the system prompt and the task itself are never dropped
-- Returns how many messages went, so the UI can say so rather than leaving the
-- model to quietly lose the plot.
local function trimHistory(history)
  local dropped = 0

  -- Earlier turns first. These are finished conversations; losing them costs
  -- context but not the current job.
  while historySize(history) > HISTORY_CHAR_BUDGET do
    local task = taskIndex(history)
    if not task or task <= 2 then break end
    table.remove(history, 2)
    dropped = dropped + 1
    -- Never leave a tool result without the assistant turn that requested it;
    -- Ollama rejects that outright.
    while history[2] and history[2].role == "tool" and (taskIndex(history) or 0) > 2 do
      table.remove(history, 2)
      dropped = dropped + 1
    end
  end

  -- Still over: give up the oldest completed step of the current task, taking
  -- the assistant turn and its results together so nothing is orphaned. The
  -- two most recent messages stay, so the model always sees what just happened.
  while historySize(history) > HISTORY_CHAR_BUDGET do
    local task = taskIndex(history) or 1
    local victim = nil
    for i = task + 1, #history - 2 do
      if history[i].role == "assistant" then victim = i; break end
    end
    if not victim then break end

    table.remove(history, victim)
    dropped = dropped + 1
    while history[victim] and history[victim].role == "tool" do
      table.remove(history, victim)
      dropped = dropped + 1
    end
  end

  return dropped
end

-- runTurn(history, cb) -> replyText, err
-- `history` is mutated in place so the conversation continues naturally.
-- Callbacks (all optional): onStatus, onAssistantNote, onToolCall,
-- onToolResult, confirm.
local function runTurn(history, cb)
  cb = cb or {}
  local function status(s) if cb.onStatus then cb.onStatus(s) end end
  local emptyRetried = false

  for iteration = 1, MAX_TOOL_ITERATIONS do
    local dropped = trimHistory(history)
    if dropped > 0 and cb.onNote then
      cb.onNote(string.format(
        "context is full — dropped %d older message%s. The task itself is kept, " ..
        "but earlier steps are gone. Raise OLLAMA_NUM_CTX in /home/.env for " ..
        "longer jobs.", dropped, dropped == 1 and "" or "s"))
    end

    -- On the final pass, ask without tools. The model then has to answer in
    -- words, so running out of steps produces a real reply about what it
    -- managed rather than an error and nothing to show for the work.
    local lastPass = (iteration == MAX_TOOL_ITERATIONS)

    if lastPass then
      status("out of steps — asking for a final answer")
    else
      status(iteration == 1 and "thinking…"
                            or ("thinking… (step " .. iteration .. " of " .. MAX_TOOL_ITERATIONS .. ")"))
    end

    local msg, err = ollamaChat(history, (not lastPass) and TOOLS or nil)
    if not msg then return nil, err end

    local calls = msg.tool_calls
    local hasCalls = (type(calls) == "table" and #calls > 0)

    history[#history + 1] = {
      role = "assistant",
      content = (type(msg.content) == "string") and msg.content or "",
      tool_calls = hasCalls and calls or nil,
    }

    if not hasCalls then
      local text = msg.content
      if type(text) == "string" and text:match("%S") then
        return text
      end

      -- A reply cut off at the token limit is one cause of a blank one: the
      -- model was mid-sentence, or mid-tool-call, when it ran out.
      if lastStats and lastStats.doneReason == "length" then
        return nil, "the reply hit the " .. NUM_PREDICT .. "-token limit before " ..
                    "the model said anything usable. Raise OLLAMA_NUM_PREDICT " ..
                    "in /home/.env, or ask for something smaller."
      end

      if emptyRetried then
        return nil, "the model returned an empty reply twice — try rephrasing, " ..
                    "or /new to reset"
      end

      -- Otherwise it simply produced nothing, which small local models do
      -- occasionally even on a question they can answer. One resample costs a
      -- second and usually works; making the user retype the question does not.
      emptyRetried = true
      history[#history] = nil  -- an empty assistant turn only confuses the retry
      status("the model said nothing — asking again")

    else
      -- Several models narrate their plan in the same message as the tool call.
      -- That text is worth showing rather than silently dropping.
      if type(msg.content) == "string" and msg.content:match("%S") and cb.onAssistantNote then
        cb.onAssistantNote(msg.content)
      end

      for _, call in ipairs(calls) do
        local fn = (type(call) == "table" and call["function"]) or {}
        local name = tostring(fn.name or "?")
        local args = normaliseArgs(fn.arguments)

        if cb.onToolCall then cb.onToolCall(name, args) end

        local allowed = true
        if NEEDS_CONFIRMATION[name] and not UNSAFE then
          allowed = (cb.confirm ~= nil) and cb.confirm(name, args) or false
        end

        local result
        local impl = TOOL_IMPL[name]
        if not impl then
          result = { error = "unknown tool: " .. name }
        elseif not allowed then
          result = { error = "the user denied permission for this tool call" }
        else
          status("running " .. name .. "…")
          local ok, res = pcall(impl, args)
          result = (ok and type(res) == "table") and res or { error = tostring(res) }
        end

        local text = resultToText(result)
        if cb.onToolResult then cb.onToolResult(name, text, result.error ~= nil) end
        history[#history + 1] = { role = "tool", content = text, tool_name = name }
      end
    end
  end

  -- Only reachable if the final no-tools pass still came back with tool calls,
  -- which a well-behaved model will not do.
  return nil, "gave up after " .. MAX_TOOL_ITERATIONS ..
              " tool steps without a final answer. Ask for one step at a time, " ..
              "or raise OLLAMA_MAX_STEPS in /home/.env."
end

-- What the model needs in order to write Lua that actually runs here, and to
-- stop reaching for things this platform does not have. A long string so the
-- text stays readable and needs no escaping. Sent with every request, so it is
-- kept factual and terse rather than discursive.
local OC_BRIEF = [[

THE MACHINE YOU ARE ON
OpenOS on OpenComputers, Lua 5.3, inside Minecraft. It is not a Unix box, and
most things you would reach for on one are absent.

Lua:
- The standard library only. No LuaSocket, no LuaFileSystem, no luarocks.
- os.execute and io.popen DO NOT EXIST. Use run_command for shell work.
- os.sleep(seconds) exists and is how a program yields.
- Memory is a few megabytes in total. Building a table with one entry per byte
  of a file will run the machine out of memory; work with strings instead.
- A loop that runs too long without yielding is killed outright ("too long
  without yielding"). Call os.sleep(0) inside any long loop.

OpenComputers APIs, through require:
  component, computer, event, term, filesystem, shell, unicode, serialization,
  keyboard. The internet API exists only on a machine with an Internet Card.
- Hardware is reached through component: component.list(type) enumerates it,
  component.invoke(address, method, ...) calls it. component.gpu and
  component.modem are shortcuts to the primary of each type.
- Events are pulled, not delivered to callbacks: event.pull(timeout, name).
  event.pull DISCARDS events that do not match its filter, so anything that
  must not miss a message uses event.listen instead.
- filesystem.* does NOT resolve relative paths, but io.open does. Make a path
  absolute before handing it to a filesystem function.
- A modem message cannot exceed 8192 bytes.

The shell, which is what run_command runs:
- ls, cd, cp, mv, rm, mkdir, cat, edit, df, components, reboot, shutdown.
- There is no grep, find, sed, awk, curl, git or python. Use search_files
  rather than grep, and the file tools rather than cat and rm.
- > and >> redirect output. It is a shell, not a Lua prompt: a Lua expression
  is taken as the name of a program to run, and fails.
- Programs are .lua files. On PATH they run by name, without the extension.
]]

-- The functions a module really has, so the model uses those instead of
-- inventing plausible ones. Guessing an API is the single most common way its
-- generated code fails here.
local function describeModule(name, mod)
  if type(mod) ~= "table" then return nil end
  local fns = {}
  for k, v in pairs(mod) do
    -- Written with parentheses. Listed as bare words, they get pasted into
    -- code as bare words: the model wrote require("http").proxyAddress, which
    -- prints the function rather than calling it, and then read the result as
    -- an answer.
    if type(v) == "function" then fns[#fns + 1] = k .. "()" end
  end
  if #fns == 0 then return nil end
  table.sort(fns)
  return "  " .. name .. ": " .. table.concat(fns, ", ")
end

-- Facts read off this machine at startup, rather than assumed. A second
-- computer with different hardware gets a different, correct brief.
local function machineFacts()
  local lines = {}

  local okMem, total = pcall(function() return computer.totalMemory() end)
  local _, free = pcall(function() return computer.freeMemory() end)
  if okMem and tonumber(total) then
    lines[#lines + 1] = string.format("- Memory: %d KB total, %d KB free",
                                      math.floor(total / 1024),
                                      math.floor((tonumber(free) or 0) / 1024))
  end

  local counts = {}
  pcall(function()
    for _, ctype in component.list() do
      counts[ctype] = (counts[ctype] or 0) + 1
    end
  end)
  local names = {}
  for ctype, n in pairs(counts) do
    names[#names + 1] = (n > 1) and (ctype .. " x" .. n) or ctype
  end
  if #names > 0 then
    table.sort(names)
    lines[#lines + 1] = "- Components attached: " .. table.concat(names, ", ")
    if not counts.internet then
      lines[#lines + 1] = "- No Internet Card here. Network access goes through " ..
                          "the proxy computer via the http library below."
    end
  end

  if shell and shell.getWorkingDirectory then
    local cwd = shell.getWorkingDirectory()
    if cwd then lines[#lines + 1] = "- Working directory: " .. cwd end
  end

  local described = {}
  for _, pair in ipairs({ { "http", http }, { "json", json }, { "env", env } }) do
    local d = describeModule(pair[1], pair[2])
    if d then described[#described + 1] = d end
  end
  if #described > 0 then
    lines[#lines + 1] = "- Libraries available here, and the functions they" ..
                        " actually have (use these exact names):"
    for _, d in ipairs(described) do lines[#lines + 1] = d end
    -- Spelled out because the failure it prevents is common and silent: code
    -- that calls http.proxyAddress() without loading http first dies on a nil
    -- global, which reads like the library is broken rather than absent.
    lines[#lines + 1] = "  Load one before using it, every time:" ..
                        "  local http = require(\"http\")  then  http.proxyAddress()"
    lines[#lines + 1] = "  Anything else: read the file with read_file first" ..
                        " rather than guessing what it provides."
  end

  if #lines == 0 then return "" end
  return "\nTHIS COMPUTER RIGHT NOW\n" .. table.concat(lines, "\n") .. "\n"
end

local systemPromptCache = nil

local function systemPrompt()
  if systemPromptCache then return systemPromptCache end

  local parts = { SYSTEM_PROMPT }

  -- The brief costs a few hundred tokens of every request, which is cheap
  -- against a normal context window and ruinous against a small one: on a
  -- transport that cannot chunk, the whole conversation budget is about 5,000
  -- characters and the brief would leave no room for the actual job. So it is
  -- included when there is room, and OLLAMA_OC_BRIEF in /home/.env overrides
  -- the decision either way.
  local wanted = env and env.bool("OLLAMA_OC_BRIEF", nil) or nil
  local roomy = HISTORY_CHAR_BUDGET >= 12000
  if wanted == true or (wanted == nil and roomy) then
    parts[#parts + 1] = OC_BRIEF
    parts[#parts + 1] = machineFacts()
  end

  -- Standing instructions the user wants on every conversation, without
  -- editing this file or losing them on the next update.
  local extraPath = (env and env.get("OLLAMA_PROMPT_FILE", "/home/.ollama_prompt"))
                    or "/home/.ollama_prompt"
  local f = io.open(extraPath, "r")
  if f then
    local extra = f:read("*a")
    f:close()
    if extra and extra:match("%S") then
      parts[#parts + 1] = "\nSTANDING INSTRUCTIONS FOR THIS MACHINE\n" .. extra
    end
  end

  systemPromptCache = table.concat(parts, "\n")
  return systemPromptCache
end

local function newHistory()
  return { { role = "system", content = systemPrompt() } }
end

-- ================================== screen ==================================
-- Same component plumbing as factory.lua: this bridge does not support calling
-- methods off a component proxy, so everything goes through component.invoke.

local function findAddr(ctype)
  for addr in component.list(ctype, true) do return addr end
end

local function safeCall(addr, method, ...)
  if not addr then return nil, "no component address" end
  local r = table.pack(pcall(component.invoke, addr, method, ...))
  if not r[1] then return nil, tostring(r[2]) end
  return table.unpack(r, 2, r.n)
end

local gpuAddr = findAddr("gpu")

local C = {
  bg       = 0x000000,
  headerBg = 0x00506B,
  headerFg = 0xAEEBFF,
  label    = 0x7C8F9B,
  text     = 0xC9D7DF,
  accent   = 0x00D3F2,
  good     = 0x4CD964,
  warn     = 0xFFB300,
  bad      = 0xFF4136,
  selBg    = 0x11485C,
  selFg    = 0xFFFFFF,
  tool     = 0xB07CFF,
  dim      = 0x556570,
  modalBg  = 0x1A1A22,
}

local W, H = 80, 25
local origW, origH

local function fg(c) safeCall(gpuAddr, "setForeground", c) end
local function bg(c) safeCall(gpuAddr, "setBackground", c) end
local function gset(x, y, s) safeCall(gpuAddr, "set", x, y, s) end
local function gfill(x, y, w, h, ch) safeCall(gpuAddr, "fill", x, y, w, h, ch) end

local function fit(s, width)
  s = tostring(s or "")
  local l = ulen(s)
  if l > width then return usub(s, 1, width) end
  return s .. string.rep(" ", width - l)
end

-- ============================== touch regions ===============================
-- Rebuilt by every render pass as it draws, so what is on screen and what
-- responds to a tap cannot disagree. Most regions carry a simulated keypress
-- rather than their own logic, so touch and keyboard run identical code.

local hits = {}
local function clearHits() hits = {} end

local function addHit(x, y, w, h, action, value)
  hits[#hits + 1] = {
    x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1,
    action = action, value = value,
  }
end

local function hitAt(x, y)
  for i = #hits, 1, -1 do
    local h = hits[i]
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then return h end
  end
  return nil
end

-- ================================ transcript ================================

local GUTTER = 5                       -- width of the "you  " / "ai   " column
local function bodyLeft() return 2 + GUTTER end
local function bodyWidth() return math.max(10, W - bodyLeft()) end
local function topRow() return 2 end
local function bottomRow() return H - 3 end
local function visibleRows() return math.max(1, bottomRow() - topRow() + 1) end

local ui = {
  entries = {},      -- {kind, text} in conversation order
  lines = nil,       -- cached wrapped render of `entries`
  linesWidth = 0,    -- width `lines` was wrapped at, so a resize rewraps
  scroll = 0,        -- lines scrolled up from the bottom; 0 sticks to newest
  input = "",
  status = nil,      -- {text, kind}
  busy = false,
}

local MAX_ENTRIES = 200

local function invalidateLines() ui.lines = nil end

local function setStatus(text, kind)
  ui.status = text and { text = text, kind = kind or "info" } or nil
end

local function addEntry(kind, text)
  ui.entries[#ui.entries + 1] = { kind = kind, text = tostring(text or "") }
  while #ui.entries > MAX_ENTRIES do table.remove(ui.entries, 1) end
  ui.scroll = 0   -- new content always scrolls into view
  invalidateLines()
end

-- Greedy word wrap. Words longer than the column are pre-split so the fill
-- loop below never has to deal with one that cannot fit.
local function splitWords(rawLine, maxw)
  local words = {}
  for token in rawLine:gmatch("%S+") do
    local word = token
    while ulen(word) > maxw do
      words[#words + 1] = usub(word, 1, maxw)
      word = usub(word, maxw + 1)
    end
    if word ~= "" then words[#words + 1] = word end
  end
  return words
end

local function wrapText(s, width)
  local out = {}
  s = tostring(s or ""):gsub("\r", "")
  for sourceLine in (s .. "\n"):gmatch("([^\n]*)\n") do
    local rawLine = sourceLine:gsub("\t", "  ")
    if not rawLine:match("%S") then
      out[#out + 1] = ""
    else
      -- Keep leading indentation, which is most of what makes pasted code
      -- readable, unless it would leave no usable room for text.
      local indent = rawLine:match("^(%s*)") or ""
      if ulen(indent) > width - 8 then indent = "" end
      local room = width - ulen(indent)
      local line = nil
      for _, word in ipairs(splitWords(rawLine, room)) do
        if not line then
          line = indent .. word
        elseif ulen(line) + 1 + ulen(word) <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = indent .. word
        end
      end
      if line then out[#out + 1] = line end
    end
  end
  return out
end

local KIND_STYLE = {
  user   = { gutter = "you", gcolor = C.accent, color = C.selFg },
  ai     = { gutter = "ai",  gcolor = C.good,   color = C.text  },
  tool   = { gutter = "",    gcolor = C.tool,   color = C.tool  },
  result = { gutter = "",    gcolor = C.dim,    color = C.dim   },
  error  = { gutter = "!!",  gcolor = C.bad,    color = C.bad   },
  info   = { gutter = "",    gcolor = C.label,  color = C.label },
}

local function buildLines()
  if ui.lines and ui.linesWidth == W then return ui.lines end
  local out = {}
  local width = bodyWidth()
  for i, entry in ipairs(ui.entries) do
    local style = KIND_STYLE[entry.kind] or KIND_STYLE.info
    if i > 1 and (entry.kind == "user" or entry.kind == "ai") then
      out[#out + 1] = { gutter = "", text = "", color = C.dim, gcolor = C.dim }
    end
    local wrapped = wrapText(entry.text, width)
    if #wrapped == 0 then wrapped = { "" } end
    for j, line in ipairs(wrapped) do
      out[#out + 1] = {
        gutter = (j == 1) and style.gutter or "",
        gcolor = style.gcolor,
        text   = line,
        color  = style.color,
      }
    end
  end
  ui.lines, ui.linesWidth = out, W
  return out
end

local function maxScroll()
  return math.max(0, #buildLines() - visibleRows())
end

local function scrollBy(delta)
  ui.scroll = math.max(0, math.min(maxScroll(), ui.scroll + delta))
end

-- ================================ rendering =================================

local function drawHeader()
  bg(C.headerBg); gfill(1, 1, W, 1, " ")
  fg(C.headerFg)
  gset(2, 1, "OLLAMA")
  fg(C.selFg)
  gset(9, 1, fit(MODEL, math.max(0, W - 30)))

  local right = ""
  if lastStats then
    right = string.format("%d+%d tok", lastStats.promptTokens, lastStats.replyTokens)
  end
  -- The badge is always here, always tappable, and always says which mode is
  -- on. Showing it only while unsafe meant it could be switched off by touch
  -- but never on, and left "safe" looking identical to "no badge drawn yet".
  local badge = UNSAFE and " UNSAFE " or " SAFE "
  local badgeX = math.max(2, W - ulen(badge))

  if right ~= "" then
    fg(C.headerFg)
    gset(math.max(10, badgeX - ulen(right) - 2), 1, right)
  end

  bg(UNSAFE and C.bad or C.good)
  fg(0x000000)
  gset(badgeX, 1, badge)
  addHit(badgeX, 1, ulen(badge), 1, "cmd", "/unsafe")
  bg(C.bg)
end

local function drawTranscript()
  bg(C.bg); gfill(1, topRow(), W, visibleRows(), " ")
  local lines = buildLines()
  local rows = visibleRows()
  local first = math.max(1, #lines - rows + 1 - ui.scroll)

  for i = 0, rows - 1 do
    local line = lines[first + i]
    if line then
      local y = topRow() + i
      if line.gutter ~= "" then
        fg(line.gcolor); gset(2, y, line.gutter)
      end
      if line.text ~= "" then
        fg(line.color); gset(bodyLeft(), y, fit(line.text, bodyWidth()))
      end
    end
  end

  -- Whole transcript area scrolls on tap: top third goes back through the
  -- conversation, bottom third comes forward. ui.scroll counts lines back from
  -- the newest, so "up" is the positive direction.
  local third = math.max(1, math.floor(rows / 3))
  addHit(1, topRow(), W, third, "scroll", third)
  addHit(1, bottomRow() - third + 1, W, third, "scroll", -third)

  if ui.scroll > 0 then
    local tag = " " .. ui.scroll .. " lines below · tap here for newest "
    bg(C.selBg); fg(C.accent)
    gset(math.max(1, W - ulen(tag)), bottomRow(), tag)
    addHit(math.max(1, W - ulen(tag)), bottomRow(), ulen(tag), 1, "cmd", "__bottom")
    bg(C.bg)
  end
end

local function drawInput()
  local y = H - 2
  bg(C.selBg); gfill(1, y, W, 1, " ")
  fg(C.accent); gset(2, y, "›")

  local room = W - 5
  local shown = ui.input
  if ulen(shown) > room then shown = usub(shown, ulen(shown) - room + 1) end
  fg(C.selFg)
  gset(4, y, shown .. (ui.busy and "" or "_"))
  addHit(1, y, W, 1, "none")
  bg(C.bg)
end

local function drawStatus()
  local y = H - 1
  bg(C.bg); gfill(1, y, W, 1, " ")
  if ui.status then
    local colors = { info = C.label, good = C.good, warn = C.warn, bad = C.bad }
    fg(colors[ui.status.kind] or C.label)
    gset(2, y, fit(ui.status.text, W - 2))
  end
end

-- Footer buttons. Each entry is {key, description, action, value}; a tap runs
-- exactly what the key would.
local function drawHintBar(entries)
  bg(C.bg); gfill(1, H, W, 1, " ")
  local x = 2
  for _, e in ipairs(entries) do
    local key, desc, action, value, colour = e[1], e[2], e[3], e[4], e[5]
    local chip = " " .. key .. " "
    local width = ulen(chip) + ((desc ~= "") and (1 + ulen(desc)) or 0)
    if x + width > W then break end

    bg(action and C.selBg or C.bg)
    fg(colour or C.accent); gset(x, H, chip)
    bg(C.bg)
    if desc ~= "" then
      fg(C.label); gset(x + ulen(chip) + 1, H, desc)
    end
    if action then addHit(x, H, width, 1, action, value) end
    x = x + width + 2
  end
  bg(C.bg)
end

local function render()
  if not gpuAddr then return end
  clearHits()
  drawHeader()
  drawTranscript()
  drawInput()
  drawStatus()
  drawHintBar({
    { "Send",  "",     "key",    "enter" },
    { "▲",     "",     "scroll", 3 },
    { "▼",     "",     "scroll", -3 },
    { "Clear", "line", "key",    "clear" },
    -- Reads as what tapping it will DO, not as the current state, so it
    -- cannot be misread the way a bare status label can.
    { UNSAFE and "Go safe" or "Go unsafe", "", "cmd", "/unsafe",
      UNSAFE and C.good or C.bad },
    { "/new",  "",     "cmd",    "/new" },
    { "/help", "",     "cmd",    "/help" },
    { "Exit",  "",     "cmd",    "/exit" },
  })
end

-- ============================= confirmation modal ===========================
-- Draws over the chat and pulls its own events, so a permission prompt works
-- the same whether it is answered by key or by tap.

local function confirmModal(name, args)
  local argText = json.encode(args)
  if #argText > 300 then argText = argText:sub(1, 300) .. "…" end

  local boxW = math.min(W - 4, 64)
  local body = wrapText(argText, boxW - 4)
  local boxH = math.min(H - 4, 7 + math.min(#body, 6))
  local x0 = math.floor((W - boxW) / 2) + 1
  local y0 = math.floor((H - boxH) / 2) + 1

  local function draw()
    clearHits()
    bg(C.modalBg); gfill(x0, y0, boxW, boxH, " ")
    fg(C.warn); gset(x0 + 2, y0 + 1, "Allow this tool call?")
    fg(C.tool); gset(x0 + 2, y0 + 2, fit(name, boxW - 4))
    fg(C.dim)
    for i = 1, math.min(#body, boxH - 7) do
      gset(x0 + 2, y0 + 3 + i, fit(body[i], boxW - 4))
    end

    local yb = y0 + boxH - 2
    bg(C.good); fg(0x000000); gset(x0 + 2, yb, "  Y  allow  ")
    addHit(x0 + 2, yb, 12, 1, "confirm", true)
    bg(C.bad); fg(0xFFFFFF); gset(x0 + 16, yb, "  N  deny  ")
    addHit(x0 + 16, yb, 11, 1, "confirm", false)
    bg(C.modalBg); fg(C.dim)
    local hint = "Enter = allow"
    if boxW > 46 then gset(x0 + boxW - ulen(hint) - 2, yb, hint) end
    bg(C.bg)
  end

  draw()
  while true do
    local e, _, p1, p2 = event.pull(30)
    if e == "key_down" then
      local ch = (p1 and p1 > 0) and string.char(p1):lower() or ""
      if ch == "y" or p2 == 28 then return true end
      if ch == "n" or p2 == 211 or p2 == 1 then return false end
    elseif e == "touch" then
      local h = hitAt(p1, p2)
      if h and h.action == "confirm" then return h.value end
    elseif e == nil then
      draw()   -- redraw periodically so a screen resize cannot strand the box
    end
  end
end

-- ================================ chat driver ===============================

local history = newHistory()
local running = true

local callbacks = {
  onStatus = function(s)
    ui.busy = true
    setStatus(s, "info")
    render()
  end,

  onAssistantNote = function(text)
    addEntry("ai", text)
    render()
  end,

  -- Things the user needs to know about the run itself, like the context
  -- filling up. Silent trimming is what makes a long job appear to lose its
  -- way for no reason.
  onNote = function(text)
    addEntry("info", text)
    render()
  end,

  onToolCall = function(name, args)
    local a = json.encode(args)
    if #a > 120 then a = a:sub(1, 120) .. "…" end
    addEntry("tool", "> " .. name .. "  " .. a)
    render()
  end,

  onToolResult = function(name, text, isError)
    -- Tool output can be thousands of characters. Show enough to follow what
    -- happened; the model still receives the full (truncated) result.
    local shown, total = {}, 0
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
      total = total + 1
      if total <= 6 then shown[#shown + 1] = line end
    end
    local body = table.concat(shown, "\n")
    if total > 6 then body = body .. "\n... " .. (total - 6) .. " more lines" end
    addEntry(isError and "error" or "result", body)
    render()
  end,

  confirm = function(name, args)
    ui.busy = false
    local allowed = confirmModal(name, args)
    render()
    return allowed
  end,
}

local function sendMessage(text)
  addEntry("user", text)
  history[#history + 1] = { role = "user", content = text }
  ui.busy = true
  render()

  local reply, err = runTurn(history, callbacks)
  ui.busy = false

  if reply then
    addEntry("ai", reply)
    if lastStats then
      setStatus(string.format("%d prompt + %d reply tokens in %.1fs",
                              lastStats.promptTokens, lastStats.replyTokens,
                              lastStats.seconds), "good")
    else
      setStatus(nil)
    end
  else
    addEntry("error", tostring(err))
    setStatus("that turn failed - see above", "bad")
  end
  render()
end

-- ================================= commands =================================

local function checkConnection(quiet)
  setStatus("contacting Ollama at " .. OLLAMA_HOST .. " ...", "info")
  render()

  local models, err = listModels()
  if not models then
    addEntry("error", "Could not reach Ollama.\n" .. tostring(err))
    setStatus("not connected - fix the above, then run /models to retry", "bad")
    return false
  end

  local found = false
  for _, n in ipairs(models) do
    if n == MODEL or n:gsub(":latest$", "") == MODEL then found = true end
  end

  if not found then
    addEntry("error", MODEL .. " is not installed on the Ollama host.\n" ..
      "Run this on that machine:  ollama pull " .. MODEL .. "\n" ..
      "Installed right now: " .. (#models > 0 and table.concat(models, ", ") or "(none)"))
    setStatus("model missing - pull it, or use /model to pick an installed one", "bad")
    return false
  end

  if not quiet then
    setStatus("loading " .. MODEL .. " into VRAM ...", "info")
    render()
    local ok, werr = warmModel()
    if not ok then
      -- Not fatal: the first real message will just pay the load cost itself.
      addEntry("info", "Model preload skipped: " .. tostring(werr))
    end
  end

  setStatus("connected to " .. OLLAMA_HOST .. " - " .. MODEL, "good")
  return true
end

local function saveTranscript(path)
  if not path or path == "" then
    setStatus("usage: /save <path>", "warn")
    return
  end
  local f, err = io.open(path, "w")
  if not f then
    setStatus("could not write " .. path .. ": " .. tostring(err), "bad")
    return
  end
  for _, e in ipairs(ui.entries) do
    f:write("[" .. e.kind .. "] " .. e.text .. "\n\n")
  end
  f:close()
  setStatus("saved transcript to " .. path, "good")
end

local HELP_TEXT =
  "Type a message and press Enter (or tap Send).\n" ..
  "Commands:\n" ..
  "  /new             start a fresh conversation\n" ..
  "  /model <name>    switch model\n" ..
  "  /models          list models installed on the Ollama host\n" ..
  "  /host <url>      point at a different Ollama instance\n" ..
  "  /tools           list the tools the model can call\n" ..
  "  /diag            probe the connection and report exactly what came back\n" ..
  "  /prompt          show the system prompt the model is given\n" ..
  "  /last            show the messages sent in the last request\n" ..
  "  /unsafe          toggle skipping permission prompts\n" ..
  "  /save <path>     write this conversation to a file\n" ..
  "  /help            this list\n" ..
  "  /exit            quit\n" ..
  "Keys: Enter send - Backspace edit - Delete clear the line -\n" ..
  "      Up/Down and PageUp/PageDown scroll - Home oldest - End newest.\n" ..
  "The screen is touch enabled: tap the top or bottom of the transcript to\n" ..
  "scroll, and tap any footer button."

local function runCommand(line)
  local cmd, rest = line:match("^(/%S+)%s*(.*)$")
  cmd = (cmd or line):lower()

  if cmd == "/exit" or cmd == "/quit" then
    running = false

  elseif cmd == "/help" then
    addEntry("info", HELP_TEXT)

  elseif cmd == "/new" then
    history = newHistory()
    ui.entries = {}
    invalidateLines()
    addEntry("info", "New conversation. Model: " .. MODEL)
    setStatus("history cleared", "good")

  elseif cmd == "/model" then
    if rest == "" then
      setStatus("current model: " .. MODEL .. "  (usage: /model <name>)", "info")
    else
      MODEL = rest
      history = newHistory()
      addEntry("info", "Switched to " .. MODEL .. ". History reset, since the " ..
                       "old conversation was written for a different model.")
      checkConnection(true)
    end

  elseif cmd == "/models" then
    local models, err = listModels()
    if not models then
      addEntry("error", tostring(err))
      setStatus("could not list models", "bad")
    else
      addEntry("info", "Installed on " .. OLLAMA_HOST .. ":\n  " ..
                       table.concat(models, "\n  "))
      setStatus(#models .. " models installed", "good")
    end

  elseif cmd == "/host" then
    if rest == "" then
      setStatus("current host: " .. OLLAMA_HOST .. "  (usage: /host <url>)", "info")
    else
      OLLAMA_HOST = rest:gsub("/+$", "")
      addEntry("info", "Ollama host set to " .. OLLAMA_HOST)
      checkConnection(true)
    end

  elseif cmd == "/tools" then
    local names = {}
    for _, t in ipairs(TOOLS) do
      local f = t["function"]
      names[#names + 1] = "  " .. f.name ..
        (NEEDS_CONFIRMATION[f.name] and "  (asks first)" or "") ..
        "\n      " .. f.description
    end
    addEntry("info", "Tools available to the model:\n" .. table.concat(names, "\n"))

  elseif cmd == "/last" then
    -- When the model reports something the tools never said, the first
    -- question is whether it was actually sent the results. This answers that
    -- instead of leaving it to be guessed at.
    if not lastPayload then
      setStatus("nothing sent yet", "warn")
    else
      local decoded = json.decode(lastPayload)
      local msgs = decoded and decoded.messages
      if type(msgs) ~= "table" then
        addEntry("info", "Last request (" .. #lastPayload .. " bytes):\n" ..
                         lastPayload:sub(1, 1500))
      else
        local out = {}
        for i, m in ipairs(msgs) do
          local body = (type(m.content) == "string") and m.content or ""
          body = body:gsub("%s+", " ")
          if #body > 90 then body = body:sub(1, 90) .. "…" end
          local tag = m.role
          if m.tool_name then tag = tag .. "/" .. m.tool_name end
          if m.tool_calls then
            local names = {}
            for _, c in ipairs(m.tool_calls) do
              local f = c["function"] or {}
              names[#names + 1] = tostring(f.name or "?")
            end
            body = "[calls: " .. table.concat(names, ", ") .. "] " .. body
          end
          out[#out + 1] = string.format("%2d %-14s %s", i, tag, body)
        end
        addEntry("info", string.format("Last request: %d messages, %d bytes\n%s",
                                       #msgs, #lastPayload, table.concat(out, "\n")))
      end
      setStatus("this is exactly what the model was given", "info")
    end

  elseif cmd == "/prompt" then
    local text = systemPrompt()
    addEntry("info", text)
    setStatus(string.format("system prompt: %d characters, roughly %d tokens of " ..
                            "every request", #text, math.floor(#text / 3.6)), "info")

  elseif cmd == "/diag" then
    addEntry("info", "Probing " .. OLLAMA_HOST .. " through " .. tostring(httpPath) ..
                     "\nWatch the proxy computer's screen while this runs.")
    render()
    addEntry("info", probeRaw("/api/tags"))
    addEntry("info", probeRaw("/api/version"))
    setStatus("probe finished - compare the above with the proxy's own log", "info")

  elseif cmd == "/unsafe" then
    UNSAFE = not UNSAFE
    if UNSAFE then
      addEntry("info", "UNSAFE MODE ON. write_file and run_command will now run " ..
                       "without asking. Run /unsafe again to turn it back off.")
      setStatus("unsafe mode on - tool calls run unattended", "bad")
    else
      addEntry("info", "Unsafe mode off. Changes to this computer will ask first.")
      setStatus("unsafe mode off", "good")
    end

  elseif cmd == "/save" then
    saveTranscript(rest)

  else
    setStatus("unknown command " .. cmd .. " - try /help", "warn")
  end
end

-- ============================== input handling ==============================

local KEY_ENTER, KEY_BACK, KEY_DELETE, KEY_ESC = 28, 14, 211, 1
local KEY_UP, KEY_DOWN, KEY_PGUP, KEY_PGDN = 200, 208, 201, 209
local KEY_HOME, KEY_END = 199, 207

local function handleKey(char, code)
  if ui.busy then return end

  if code == KEY_ENTER then
    local text = ui.input
    ui.input = ""
    if text:match("%S") then
      if text:sub(1, 1) == "/" then runCommand(text) else sendMessage(text) end
    end

  elseif code == KEY_BACK then
    ui.input = usub(ui.input, 1, math.max(0, ulen(ui.input) - 1))

  -- Minecraft swallows Esc before OpenComputers ever sees it, so Delete is
  -- the clear-the-line key here, exactly as it is in factory.lua.
  elseif code == KEY_DELETE or code == KEY_ESC then
    ui.input = ""

  elseif code == KEY_UP then scrollBy(1)
  elseif code == KEY_DOWN then scrollBy(-1)
  elseif code == KEY_PGUP then scrollBy(visibleRows())
  elseif code == KEY_PGDN then scrollBy(-visibleRows())
  elseif code == KEY_HOME then ui.scroll = maxScroll()
  elseif code == KEY_END then ui.scroll = 0

  elseif char and char >= 32 and char < 127 then
    ui.input = ui.input .. string.char(char)
  end
end

local function handleTouch(x, y)
  local h = hitAt(x, y)
  if not h then return end
  if h.action == "scroll" then
    scrollBy(h.value)
  elseif h.action == "key" then
    if h.value == "enter" then handleKey(nil, KEY_ENTER)
    elseif h.value == "clear" then ui.input = "" end
  elseif h.action == "cmd" then
    if h.value == "__bottom" then ui.scroll = 0 else runCommand(h.value) end
  end
end

-- ================================ entry points ==============================

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

local function runInteractive()
  setup()
  bg(C.bg); gfill(1, 1, W, H, " ")

  addEntry("info",
    "Ollama chat with tool access to this computer.\n" ..
    "http.lua loaded from " .. tostring(httpPath) .. "\n" ..
    "Type /help for commands. The screen is touch enabled.")
  render()
  checkConnection(false)
  render()

  while running do
    local e, _, p1, p2, p3 = event.pull(5)

    if e == "key_down" then
      handleKey(p1, p2)
    elseif e == "touch" then
      handleTouch(p1, p2)
    elseif e == "scroll" then
      -- Wheel direction is positive for up, which means further back.
      scrollBy((p3 or 0) > 0 and 3 or -3)
    elseif e == "clipboard" then
      -- Pasting is far easier than typing a long prompt on an in-game keyboard.
      local pasted = tostring(p1 or ""):gsub("[\r\n]", " ")
      ui.input = ui.input .. pasted
    end

    -- A screen swapped underneath us changes the resolution; rewrap rather
    -- than render the old layout into the new size.
    local nw, nh = safeCall(gpuAddr, "getResolution")
    if nw and nh and (nw ~= W or nh ~= H) then
      W, H = nw, nh
      invalidateLines()
    end

    render()
  end

  teardown()
end

local function runOneShot(question)
  print("[ollama] " .. MODEL .. " - thinking...")
  local hist = newHistory()
  hist[#hist + 1] = { role = "user", content = question }

  local reply, err = runTurn(hist, {
    onStatus = function(s) print("[ollama] " .. s) end,
    onNote = function(s) print("[ollama] " .. s) end,
    onToolCall = function(name, args)
      print("[tool] " .. name .. " " .. json.encode(args))
    end,
    onToolResult = function(name, text, isError)
      print("[tool] " .. (isError and "error: " or "-> ") .. tostring(text):sub(1, 300))
    end,
    confirm = function(name, args)
      io.write("[ollama] allow " .. name .. "(" .. json.encode(args) .. ")? [y/N] ")
      local answer = io.read()
      return answer ~= nil and answer:lower():sub(1, 1) == "y"
    end,
  })

  if reply then
    print("")
    print(reply)
    print("")
  else
    print("[ollama] Error: " .. tostring(err))
  end
end

-- ============================== argument parsing ============================

local words = {}
for _, a in ipairs({ ... }) do
  if a == "-u" or a == "--unsafe" then
    UNSAFE = true
  elseif a:match("^%-%-model=") then
    MODEL = a:match("^%-%-model=(.+)$") or MODEL
  elseif a:match("^%-%-host=") then
    OLLAMA_HOST = (a:match("^%-%-host=(.+)$") or OLLAMA_HOST):gsub("/+$", "")
  elseif a == "-h" or a == "--help" then
    print("ollama [-u] [--model=NAME] [--host=URL] [question...]")
    print("  no question  start the full-screen chat UI")
    print("  -u           skip tool confirmation prompts (unsafe mode)")
    return
  else
    words[#words + 1] = a
  end
end

if #words > 0 then
  runOneShot(table.concat(words, " "))
elseif not gpuAddr then
  print("ollama.lua: no GPU component found, so the chat UI cannot start.")
  print("Pass a question on the command line instead:  ollama \"your question\"")
else
  local ok, err = pcall(runInteractive)
  if not ok then
    teardown()
    print("ollama.lua crashed: " .. tostring(err))
  end
end
