"""Exercise proxy.lua's HTTP read path against a simulated Internet Card.

OpenComputers' internet.request() is asynchronous: the handle is returned
before the connection exists, finishConnect() reports progress, and read()
returns "" for "connected but nothing buffered yet" versus nil for genuine
end-of-stream.

These tests also pin down three regressions introduced by an earlier attempt at
that fix, each of which broke a proxy that had been working:
  - sleeping inside request handling silently lost queued requests
  - a read timeout raised and discarded a body it had already read
  - a stream ending with "" instead of nil stalled for the full timeout

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
  handleRequest = handleRequest,
  isAllowed = isAllowed,
  fmtStatus = fmtStatus,
  setTimeouts = function(c, r, g)
    CONNECT_TIMEOUT = c; READ_TIMEOUT = r; EMPTY_GRACE = g or EMPTY_GRACE
  end,
}
"""

PRELUDE = r"""
_G.__sent = {}

-- Fake request handle. `connectAfter` is how many finishConnect() calls return
-- false before it succeeds; `reads` is what read() hands back in order, where
-- "" means "nothing yet", "__EOF__" means nil (end of stream) and "__RAISE__"
-- makes read() throw.
function __makeHandle(connectAfter, reads, connectFails, responseTuple)
  local h = {}
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
    if v == "__RAISE__" then error("connection lost") end
    return v
  end
  h.response = function()
    if responseTuple == nil then return nil end
    return responseTuple[1], responseTuple[2], responseTuple[3]
  end
  h.close = function() end
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
  event = { pull = function() return nil end, listen = function() return true end },
  serialization = {
    serialize = function(t)
      local parts = {}
      for k, v in pairs(t) do
        if type(v) == "table" then
          local inner = {}
          for ik, iv in pairs(v) do inner[#inner + 1] = tostring(ik) .. ":" .. tostring(iv) end
          parts[#parts + 1] = tostring(k) .. "={" .. table.concat(inner, ",") .. "}"
        else
          parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
      end
      return table.concat(parts, "&")
    end,
    unserialize = function(s) return s end,
  },
}

require = function(name) return stubs[name] end

-- Real time would make the timeout tests take most a minute; run the clock fast.
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
    return lua.globals()["__makeHandle"](
        connect_after,
        lua.table_from(list(reads)),
        fails,
        lua.table_from(list(response)) if response else None)


# pcall returns only `true` when the call succeeds and returns nothing, which
# cannot be unpacked into two names. Always hand back a pair.
pcall = lua.eval(
    "function(f,a,b,c,d) local ok, e = pcall(f,a,b,c,d); return ok, tostring(e) end")
G = lua.globals()
do = mod["doHttpRequest"]

print("== the async connection race ==")
G["__nextHandle"] = handle(connect_after=3,
                           reads=["", "", '{"models":[]}', "__EOF__"],
                           response=[200, "OK", None])
res = do("GET", "http://127.0.0.1:11434/api/tags", None, None)
check("a body that needs waiting for is not lost",
      res["body"] == '{"models":[]}', res["body"])
check("the status is the real one, not a guess", res["statusKnown"] is True)

G["__nextHandle"] = handle(connect_after=5, reads=["", "", "", "hello ", "world", "__EOF__"])
res = do("GET", "http://x/", None, None)
check("chunks are concatenated in order", res["body"] == "hello world", res["body"])
check("a card that reports no status falls back to a flagged 200",
      res["status"] == 200 and res["statusKnown"] is False,
      (res["status"], res["statusKnown"]))

print("== never discard a body that already arrived ==")
# Regression: an earlier version raised on read timeout, throwing away
# everything it had read. A partial body beats no body.
mod["setTimeouts"](10, 2, 2)
G["__nextHandle"] = handle(connect_after=0, reads=["partial data", "__RAISE__"])
res = do("GET", "http://x/", None, None)
check("a read error after data returns what arrived",
      res is not None and res["body"] == "partial data",
      res["body"] if res else None)

# Regression: a stream that ends with "" rather than nil stalled for the whole
# read timeout on every single request, which pushed clients past their own.
G["__nextHandle"] = handle(connect_after=0, reads=["the body"] + [""] * 5000)
res = do("GET", "http://x/", None, None)
check("empty reads after data end the body instead of stalling",
      res["body"] == "the body", res["body"])

G["__nextHandle"] = handle(connect_after=0, reads=["a", "", "", "b", "", "c", "__EOF__"])
res = do("GET", "http://x/", None, None)
check("a gap mid-body does not end it early", res["body"] == "abc", res["body"])
mod["setTimeouts"](10, 25, 2)

print("== connection failures ==")
G["__nextHandle"] = handle(fails=True, reads=["__EOF__"])
ok, err = pcall(do, "GET", "http://x/")
check("a refused connection raises instead of returning an empty body",
      ok is False and "connection refused" in str(err), (ok, err))

# A card that never gives a definite answer should still be tried, because the
# original code did not wait at all and worked for most hosts.
mod["setTimeouts"](1, 5, 1)
G["__nextHandle"] = handle(connect_after=10 ** 6, reads=["late body", "__EOF__"])
res = do("GET", "http://x/", None, None)
check("a connection that never settles is still read rather than failed",
      res is not None and res["body"] == "late body", res["body"] if res else None)

G["__nextHandle"] = handle(connect_after=0, reads=[""] * 10000)
ok, err = pcall(do, "GET", "http://x/")
check("a socket that never sends anything at all does raise",
      ok is False and "no data after" in str(err), (ok, err))
mod["setTimeouts"](10, 25, 2)

print("== POST bodies ==")
G["__nextHandle"] = handle(connect_after=0, reads=["ok", "__EOF__"])
do("POST", "http://x/api/chat", None, '{"model":"q"}')
check("POST forwards the request body", G["__lastPost"] == '{"model":"q"}', G["__lastPost"])
G["__nextHandle"] = handle(connect_after=0, reads=["ok", "__EOF__"])
do("GET", "http://x/", None, "ignored")
check("GET sends no post data", G["__lastPost"] is None, G["__lastPost"])

print("== modem size limit ==")


def reset_sent():
    sent = G["__sent"]
    while len(sent) > 0:
        sent[len(sent)] = None


# Headers on an API response can outweigh the body; dropping them should
# rescue a reply that would otherwise be refused outright.
reset_sent()
big_headers = {"h%03d" % i: "x" * 200 for i in range(100)}
mod["sendTo"]("addr", "response", lua.table_from({
    "id": "7", "body": "the real payload", "headers": lua.table_from(big_headers)}))
payload = G["__sent"][1]
check("headers are dropped to fit rather than losing the reply",
      "body=the real payload" in payload and len(payload) <= 8192, len(payload))
check("dropping headers actually removed them",
      "h001" not in payload, payload[:80])

reset_sent()
mod["sendTo"]("addr", "response", lua.table_from({"id": "8", "body": "x" * 9000}))
payload = G["__sent"][1]
check("a reply too big even without headers becomes an error",
      "error=" in payload and len(payload) < 8192, len(payload))
check("the error reply keeps the request id so the client can match it",
      "id=8" in payload, payload[:60])

reset_sent()
mod["sendTo"]("addr", "response", lua.table_from({"id": "9", "body": "small"}))
check("a normal reply passes through untouched", "body=small" in G["__sent"][1], G["__sent"][1])

print("== misc ==")
check("an empty allowlist allows everyone", mod["isAllowed"]("anything") is True)
check("whole-number statuses print without a decimal",
      mod["fmtStatus"](200.0) == "200", mod["fmtStatus"](200.0))

# One bad request must not be able to take the proxy down.
reset_sent()
G["__nextHandle"] = None
ok, err = pcall(mod["handleRequest"], "addr", "not-a-table")
check("a malformed request is answered, not fatal", ok is True, err)

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
