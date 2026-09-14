"""Exercise proxy.lua's HTTP read path against a simulated Internet Card.

OpenComputers' internet.request() is asynchronous: the handle is returned
before the connection exists, finishConnect() reports progress, and read()
returns "" for "connected but nothing buffered yet" versus nil for genuine
end-of-stream. The original proxy conflated those, which produced empty bodies
with a defaulted "200 OK". These tests pin the distinction down.

Run:  pip install lupa && python tests/proxy_harness.py
"""
import os.path
import sys
from lupa import LuaRuntime

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "proxy.lua")

lines = open(SRC, encoding="utf-8").read().split("\n")
cut = next(i for i, l in enumerate(lines) if l.startswith("-- ==== MAIN LOOP"))
body = "\n".join(lines[:cut]) + """
return {
  doHttpRequest = doHttpRequest,
  sendTo = sendTo,
  isAllowed = isAllowed,
  setTimeouts = function(c, r) CONNECT_TIMEOUT = c; READ_TIMEOUT = r end,
}
"""

PRELUDE = r"""
_G.__sent = {}

-- Builds a fake request handle. `connectAfter` is how many finishConnect()
-- calls return false before it succeeds; `reads` is the sequence read() hands
-- back, where "" means "nothing yet" and nil means end of stream.
function __makeHandle(connectAfter, reads, connectFails, responseTuple)
  local h = { closed = false }
  local connectCalls, readIndex = 0, 0
  h.finishConnect = function()
    connectCalls = connectCalls + 1
    if connectFails then return nil, "connection refused" end
    if connectCalls > connectAfter then return true end
    return false
  end
  h.read = function(n)
    readIndex = readIndex + 1
    local v = reads[readIndex]
    if v == "__EOF__" then return nil end
    return v
  end
  h.response = function()
    if responseTuple == nil then return nil end
    return responseTuple[1], responseTuple[2], responseTuple[3]
  end
  h.close = function() h.closed = true end
  return h
end

_G.__nextHandle = nil

local stubs = {
  component = {
    isAvailable = function() return true end,
    internet = { request = function(url, post, headers)
      _G.__lastUrl, _G.__lastPost, _G.__lastHeaders = url, post, headers
      return _G.__nextHandle
    end },
    modem = {
      address = "fake-modem",
      open = function() end,
      send = function(addr, port, kind, payload)
        _G.__sent[#_G.__sent + 1] = payload
      end,
    },
  },
  event = { pull = function() return nil end },
  serialization = {
    serialize = function(t)
      -- Just enough to measure size and read back the fields the tests need.
      local parts = {}
      for k, v in pairs(t) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
      end
      return table.concat(parts, "&")
    end,
    unserialize = function(s) return s end,
  },
}

require = function(name) return stubs[name] end

-- Real time would make the timeout tests take half a minute; run the clock fast.
local realClock = os.clock
local fakeNow = 0
os.clock = function() return fakeNow end
os.sleep = function(n) fakeNow = fakeNow + (n or 0) + 0.01 end
"""

lua = LuaRuntime(unpack_returned_tuples=False)
lua.execute(PRELUDE)
mod = lua.execute(body)

failures = []


def check(name, cond, detail=""):
    if cond:
        print("  pass  " + name)
    else:
        print("  FAIL  " + name + ("  -> " + str(detail) if detail else ""))
        failures.append(name)


def handle(connect_after=0, reads=(), fails=False, response=None):
    mk = lua.globals()["__makeHandle"]
    return mk(connect_after,
              lua.table_from(list(reads)),
              fails,
              lua.table_from(list(response)) if response else None)


G = lua.globals()
do = mod["doHttpRequest"]

print("== the empty-body bug ==")
# The exact shape that broke the Ollama call: the connection needs a few polls
# before it is ready, and reads are empty until then.
G["__nextHandle"] = handle(connect_after=3,
                           reads=["", "", '{"models":[]}', "__EOF__"],
                           response=[200, "OK", None])
res = do("GET", "http://127.0.0.1:11434/api/tags", None, None)
check("a body that needs waiting for is not lost",
      res["body"] == '{"models":[]}', res["body"])
check("the status is the real one, not a guess", res["statusKnown"] is True)

# Before the fix, read() on an unready request returned nil and the loop
# treated it as end-of-stream. Prove an early nil no longer truncates a
# response that only starts arriving after the connection completes.
G["__nextHandle"] = handle(connect_after=5,
                           reads=["", "", "", "hello ", "world", "__EOF__"])
res = do("GET", "http://x/", None, None)
check("chunks are concatenated in order", res["body"] == "hello world", res["body"])
check("a card that reports no status falls back to a flagged 200",
      res["status"] == 200 and res["statusKnown"] is False,
      (res["status"], res["statusKnown"]))

print("== connection failures ==")
G["__nextHandle"] = handle(fails=True, reads=["__EOF__"])
ok, err = lua.eval("function(f,a,b) return pcall(f,a,b) end")(do, "GET", "http://x/")
check("a refused connection raises instead of returning an empty body",
      ok is False and "connection refused" in str(err), (ok, err))

mod["setTimeouts"](2, 2)
G["__nextHandle"] = handle(connect_after=10 ** 6, reads=["__EOF__"])
ok, err = lua.eval("function(f,a,b) return pcall(f,a,b) end")(do, "GET", "http://x/")
check("a connection that never completes times out",
      ok is False and "timed out connecting" in str(err), (ok, err))

G["__nextHandle"] = handle(connect_after=0, reads=[""] * 10000)
ok, err = lua.eval("function(f,a,b) return pcall(f,a,b) end")(do, "GET", "http://x/")
check("a connected socket that never sends anything times out",
      ok is False and "timed out reading" in str(err), (ok, err))
mod["setTimeouts"](15, 30)

print("== slow but progressing responses ==")
# Progress must reset the read deadline, or a large slow body dies halfway.
mod["setTimeouts"](15, 2)
reads = []
for i in range(40):
    reads += ["", "", "chunk%d " % i]
reads.append("__EOF__")
G["__nextHandle"] = handle(connect_after=0, reads=reads)
res = do("GET", "http://x/", None, None)
check("a slow body that keeps making progress is not cut off",
      res["body"].startswith("chunk0 ") and res["body"].rstrip().endswith("chunk39"),
      res["body"][:30] + " ... " + res["body"][-20:])
mod["setTimeouts"](15, 30)

print("== POST bodies ==")
G["__nextHandle"] = handle(connect_after=0, reads=["ok", "__EOF__"])
do("POST", "http://x/api/chat", None, '{"model":"q"}')
check("POST forwards the request body",
      G["__lastPost"] == '{"model":"q"}', G["__lastPost"])
G["__nextHandle"] = handle(connect_after=0, reads=["ok", "__EOF__"])
do("GET", "http://x/", None, "ignored")
check("GET sends no post data", G["__lastPost"] is None, G["__lastPost"])

print("== modem size limit ==")
sent = G["__sent"]
while len(sent) > 0:
    sent[len(sent)] = None
mod["sendTo"]("addr", "response", lua.table_from({"id": "7", "body": "x" * 9000}))
payload = G["__sent"][1]
check("an oversized reply is replaced with an error, not silently dropped",
      "error=" in payload and len(payload) < 8192, len(payload))
check("the error reply keeps the request id so the client can match it",
      "id=7" in payload, payload[:60])

mod["sendTo"]("addr", "response", lua.table_from({"id": "8", "body": "small"}))
check("a normal reply passes through untouched",
      "body=small" in G["__sent"][2], G["__sent"][2])

print("== allowlist ==")
check("an empty allowlist allows everyone", mod["isAllowed"]("anything") is True)

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
