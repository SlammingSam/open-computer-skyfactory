-- nettest.lua — probe the Internet Card directly, on the PROXY COMPUTER.
--
-- Run this on the machine that has the Internet Card, not on the client. It
-- talks to the card with no modem, no proxy protocol and no JSON in the way,
-- and reports what every call actually returns, so a failure can be located
-- instead of inferred from an empty body two machines away.
--
--   nettest              probe every URL in URLS below, then raw TCP
--   nettest <url>        probe just that URL
--
-- Results are printed and also written to /home/nettest.txt.

local component = require("component")

if not component.isAvailable("internet") then
  print("nettest: this computer has no Internet Card. Run it on the proxy.")
  return
end

local internet = component.internet

-- Edit freely. The point of the list is contrast: if GitHub works and the
-- local address does not, the card is refusing local addresses; if plain HTTP
-- fails everywhere, it is the protocol; if only the odd port fails, it is the
-- port.
local URLS = {
  "http://127.0.0.1:11434/api/version",   -- the one that matters
  "http://localhost:11434/api/version",   -- same host, by name
  "http://example.com",                   -- plain HTTP, standard port, remote
  "https://raw.githubusercontent.com/SlammingSam/open-computer-skyfactory/main/OLLAMA.md",
}

-- Raw TCP target, tried after the HTTP probes. If TCP to the same address
-- works while internet.request() does not, the block is in the card's HTTP
-- path and the proxy can be rewritten to speak HTTP over a socket instead.
local TCP_HOST, TCP_PORT, TCP_PATH = "127.0.0.1", 11434, "/api/version"

local CONNECT_WAIT = 10   -- seconds to wait for a connection
local READ_WAIT    = 10   -- seconds to wait for data

-- ============================== output ======================================

local lines = {}
local function say(fmt, ...)
  local line = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
  print(line)
  lines[#lines + 1] = line
end

local function clean(s)
  return (tostring(s):gsub("[\r\n]", " "):gsub("[^%g ]", "."))
end

-- ============================ card capabilities =============================

local function probeCard()
  say("=== Internet Card ===")
  for _, name in ipairs({ "isHttpEnabled", "isTcpEnabled" }) do
    if type(internet[name]) ~= "nil" then
      local ok, value = pcall(internet[name])
      say("  %s: %s", name, ok and tostring(value) or ("raised " .. tostring(value)))
    else
      say("  %s: not available on this card", name)
    end
  end
end

-- ============================== HTTP probe ==================================

local function probeHttp(url)
  say("")
  say("=== GET %s", url)

  local ok, handle = pcall(internet.request, url)
  if not ok then
    say("  request() RAISED: %s", clean(handle))
    say("  -> the card refused outright. This is usually the blacklist.")
    return
  end
  if not handle then
    say("  request() returned nil")
    return
  end

  local methods = {}
  for _, m in ipairs({ "finishConnect", "read", "response", "close", "write" }) do
    if type(handle[m]) ~= "nil" then methods[#methods + 1] = m end
  end
  say("  handle methods: %s", table.concat(methods, ", "))

  -- finishConnect: true = connected, false = still working, nil+err = failed.
  if type(handle.finishConnect) ~= "nil" then
    local polls, deadline, settled = 0, os.clock() + CONNECT_WAIT, false
    while os.clock() < deadline do
      polls = polls + 1
      local cok, a, b = pcall(handle.finishConnect)
      if not cok then
        say("  finishConnect RAISED after %d polls: %s", polls, clean(a))
        settled = true
        break
      elseif a == true then
        say("  finishConnect -> true after %d polls", polls)
        settled = true
        break
      elseif a == nil then
        say("  finishConnect -> nil, %s  (after %d polls)", clean(b), polls)
        say("  -> the connection failed. The message above is the real reason.")
        settled = true
        break
      end
      os.sleep(0.05)
    end
    if not settled then
      say("  finishConnect never settled in %ds (%d polls, still false)", CONNECT_WAIT, polls)
    end
  else
    say("  no finishConnect on this handle")
  end

  -- response(): status line and headers, once they exist.
  if type(handle.response) ~= "nil" then
    local rok, code, msg, hdrs = pcall(handle.response)
    if not rok then
      say("  response() RAISED: %s", clean(code))
    elseif code == nil then
      say("  response() -> nil  (no status yet or never arrived)")
    else
      say("  response() -> %s %s", tostring(code), clean(msg))
      if type(hdrs) == "table" then
        local shown = 0
        for k, v in pairs(hdrs) do
          shown = shown + 1
          if shown <= 6 then
            if type(v) == "table" then v = table.concat(v, ", ") end
            say("      %s: %s", tostring(k), clean(v):sub(1, 60))
          end
        end
        if shown == 0 then say("      (no headers)") end
      end
    end
  end

  -- read(): a string means data, "" means nothing buffered yet, nil means the
  -- stream has genuinely ended.
  local total, reads, empties, shown = 0, 0, 0, 0
  local deadline = os.clock() + READ_WAIT
  while os.clock() < deadline do
    local kok, chunk = pcall(handle.read, 8192)
    if not kok then
      say("  read() RAISED after %d reads: %s", reads, clean(chunk))
      break
    end
    reads = reads + 1
    if chunk == nil then
      say("  read() -> nil (end of stream) on read %d", reads)
      break
    elseif chunk == "" then
      empties = empties + 1
      os.sleep(0.05)
    else
      total = total + #chunk
      shown = shown + 1
      if shown <= 3 then
        say("  read() -> %d bytes: %s", #chunk, clean(chunk):sub(1, 90))
      end
      deadline = os.clock() + READ_WAIT
    end
  end

  say("  TOTAL: %d bytes over %d reads (%d of them empty)", total, reads, empties)
  if total == 0 then
    say("  -> NOTHING came back. A connection that succeeds and then delivers")
    say("     no status and no body is what a silently blocked request looks like.")
  end
  pcall(handle.close)
end

-- ============================== raw TCP probe ===============================
-- If this works while the HTTP probe above does not, the card's HTTP path is
-- the thing being blocked, and the proxy can speak HTTP over a socket instead.

local function probeTcp(host, port, path)
  say("")
  say("=== raw TCP %s:%d%s", host, port, path)

  if type(internet.connect) == "nil" then
    say("  this card has no connect() — TCP not supported")
    return
  end

  local ok, sock = pcall(internet.connect, host, port)
  if not ok then
    say("  connect() RAISED: %s", clean(sock))
    say("  -> TCP is disabled, or this address is blocked.")
    return
  end
  if not sock then
    say("  connect() returned nil")
    return
  end

  local connected, polls, deadline = false, 0, os.clock() + CONNECT_WAIT
  while os.clock() < deadline do
    polls = polls + 1
    local cok, a, b = pcall(sock.finishConnect)
    if not cok then
      say("  finishConnect RAISED: %s", clean(a))
      pcall(sock.close)
      return
    elseif a == true then
      connected = true
      say("  connected after %d polls", polls)
      break
    elseif a == nil then
      say("  finishConnect -> nil, %s", clean(b))
      pcall(sock.close)
      return
    end
    os.sleep(0.05)
  end
  if not connected then
    say("  never connected in %ds", CONNECT_WAIT)
    pcall(sock.close)
    return
  end

  local request = "GET " .. path .. " HTTP/1.1\r\n" ..
                  "Host: " .. host .. ":" .. port .. "\r\n" ..
                  "User-Agent: OpenComputers\r\n" ..
                  "Connection: close\r\n\r\n"
  local wok, werr = pcall(sock.write, request)
  if not wok then
    say("  write() RAISED: %s", clean(werr))
    pcall(sock.close)
    return
  end
  say("  wrote %d bytes of request", #request)

  local total, shown = 0, 0
  deadline = os.clock() + READ_WAIT
  while os.clock() < deadline do
    local rok, chunk = pcall(sock.read, 8192)
    if not rok then
      say("  read() RAISED: %s", clean(chunk))
      break
    end
    if chunk == nil then
      say("  read() -> nil (socket closed)")
      break
    elseif chunk == "" then
      os.sleep(0.05)
    else
      total = total + #chunk
      shown = shown + 1
      if shown <= 3 then
        say("  read() -> %d bytes: %s", #chunk, clean(chunk):sub(1, 90))
      end
      deadline = os.clock() + READ_WAIT
    end
  end
  say("  TOTAL: %d bytes", total)
  if total > 0 then
    say("  -> RAW TCP WORKS. The card can reach Ollama; only its HTTP path cannot.")
  end
  pcall(sock.close)
end

-- ================================== main ====================================

local args = { ... }
probeCard()

if #args > 0 then
  probeHttp(args[1])
else
  for _, url in ipairs(URLS) do
    probeHttp(url)
  end
  probeTcp(TCP_HOST, TCP_PORT, TCP_PATH)
end

say("")
local f = io.open("/home/nettest.txt", "w")
if f then
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  say("Saved to /home/nettest.txt")
else
  say("(could not write /home/nettest.txt)")
end
