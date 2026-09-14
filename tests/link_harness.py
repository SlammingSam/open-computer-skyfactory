"""Prove http.lua and proxy.lua agree on the chunked wire format.

A modem drops any message over 8192 bytes, and a rack relay drops what
overflows its queue. Requests are tiny and always arrive; replies are not,
which is why small pages worked while a 4 KB API response silently vanished
and the client reported only a timeout.

Both files now split large payloads into numbered chunks. They are separate
programs on separate computers that never import each other, so the one thing
that really matters is that the sender's argument order matches the receiver's
expectation -- a mismatch would look completely correct in each file on its
own. These tests send through one and receive through the other.

Run:  pip install lupa && python tests/link_harness.py
"""
import os.path
import sys
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODEM_LIMIT = 8192  # OpenComputers drops anything larger

PRELUDE = r"""
_G.__packets = {}

local function record(addr, port, kind, a, b, c, d, e)
  _G.__packets[#_G.__packets + 1] = {
    addr = addr, port = port, kind = kind, a = a, b = b, c = c, d = d, e = e,
  }
  return true
end

local stubs = {
  component = {
    isAvailable = function() return true end,
    modem = {
      address = "proxy-modem-address",
      open = function() end,
      send = record,
      broadcast = function(port, kind) return record("*", port, kind) end,
    },
    internet = { request = function() return nil end },
  },
  event = {
    pull = function() return nil end,
    listen = function() return true end,
  },
  serialization = {
    serialize = function(t) return "SERIALIZED" end,
    unserialize = function(s) return s end,
  },
}
require = function(name) return stubs[name] end
os.sleep = function() end
os.clock = function() return 0 end
"""


def load(path, cut_marker=None, exports=""):
    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute(PRELUDE)
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    if cut_marker:
        lines = src.split("\n")
        cut = next(i for i, l in enumerate(lines) if l.startswith(cut_marker))
        src = "\n".join(lines[:cut])
    else:
        # http.lua ends by returning its public table; widen that for testing.
        src = src.rsplit("return http", 1)[0]
    return lua, lua.execute(src + exports)


proxy_lua, proxy = load("bin/proxy.lua", "-- ==== MAIN LOOP", """
return {
  sendSerialized = sendSerialized,
  collectChunk = collectChunk,
  CHUNK_BYTES = CHUNK_BYTES,
}
""")

http_lua, client = load("lib/http.lua", None, """
return {
  sendSerialized = sendSerialized,
  collectChunk = collectChunk,
  CHUNK_BYTES = CHUNK_BYTES,
  setTimeout = http.setTimeout,
  getTimeout = http.getTimeout,
}
""")

failures = []


def check(name, cond, detail=""):
    if cond:
        print("  pass  " + name)
    else:
        print("  FAIL  " + name + ("  -> " + str(detail) if detail else ""))
        failures.append(name)


def packets_of(lua):
    got = lua.globals()["__packets"]
    out = []
    for i in range(1, len(got) + 1):
        p = got[i]
        out.append({k: p[k] for k in ("addr", "port", "kind", "a", "b", "c", "d", "e")})
    return out


def reset(lua):
    lua.execute("_G.__packets = {}")


def wire_size(p):
    # Everything the modem has to carry, as the real one would count it.
    n = 0
    for k in ("kind", "a", "b", "c", "d", "e"):
        v = p[k]
        if isinstance(v, str):
            n += len(v)
        elif v is not None:
            n += 8
    return n


print("== chunk sizing ==")
check("both sides use the same chunk size",
      proxy["CHUNK_BYTES"] == client["CHUNK_BYTES"],
      (proxy["CHUNK_BYTES"], client["CHUNK_BYTES"]))
check("a chunk leaves room under the modem limit",
      proxy["CHUNK_BYTES"] < MODEM_LIMIT, proxy["CHUNK_BYTES"])

print("== proxy -> client (the direction that was failing) ==")
BIG = "".join("body-%05d;" % i for i in range(2000))   # ~24 KB
reset(proxy_lua)
proxy["sendSerialized"]("client-addr", "response", BIG)
sent = packets_of(proxy_lua)
check("a large reply is split rather than sent whole", len(sent) > 1, len(sent))
check("every packet fits through the modem",
      all(wire_size(p) <= MODEM_LIMIT for p in sent),
      max(wire_size(p) for p in sent))
check("chunks are labelled as chunks", all(p["kind"] == "chunk" for p in sent))

# Feed the proxy's packets into the CLIENT's reassembler, in order.
done = None
for p in sent:
    done = client["collectChunk"](p["a"], p["b"], p["c"], p["d"], p["e"])
check("the client reassembles the reply byte for byte", done == BIG,
      None if done is None else (len(done), len(BIG)))
check("reassembly only completes on the last chunk",
      all(client["collectChunk"](p["a"], p["b"], p["c"], p["d"], p["e"]) is None
          for p in sent[:-1]))
client["collectChunk"](sent[-1]["a"], sent[-1]["b"], sent[-1]["c"],
                       sent[-1]["d"], sent[-1]["e"])

print("== client -> proxy ==")
reset(http_lua)
client["sendSerialized"]("proxy-addr", "request", BIG)
sent = packets_of(http_lua)
check("a large request is split too", len(sent) > 1, len(sent))
check("every request packet fits through the modem",
      all(wire_size(p) <= MODEM_LIMIT for p in sent),
      max(wire_size(p) for p in sent))

done = None
for p in sent:
    done = proxy["collectChunk"]("client-addr", p["a"], p["b"], p["c"], p["d"], p["e"])
check("the proxy reassembles the request byte for byte", done == BIG,
      None if done is None else (len(done), len(BIG)))

print("== small messages stay on the old wire format ==")
reset(proxy_lua)
proxy["sendSerialized"]("client-addr", "response", "tiny")
sent = packets_of(proxy_lua)
check("a small reply is one plain response message",
      len(sent) == 1 and sent[0]["kind"] == "response" and sent[0]["a"] == "tiny",
      sent)

reset(http_lua)
client["sendSerialized"]("proxy-addr", "request", "tiny")
sent = packets_of(http_lua)
check("a small request is one plain request message",
      len(sent) == 1 and sent[0]["kind"] == "request" and sent[0]["a"] == "tiny",
      sent)

print("== reassembly robustness ==")
reset(proxy_lua)
proxy["sendSerialized"]("client-addr", "response", BIG)
sent = packets_of(proxy_lua)

# Packets can arrive out of order, and a rack can duplicate on retry.
shuffled = sent[2:] + sent[:2]
done = None
for p in shuffled:
    r = client["collectChunk"](p["a"], p["b"], p["c"], p["d"], p["e"])
    if r is not None:
        done = r
check("out-of-order chunks still reassemble correctly", done == BIG,
      None if done is None else len(done))

done = None
for p in sent + sent[:3]:
    r = client["collectChunk"](p["a"], p["b"], p["c"], p["d"], p["e"])
    if r is not None:
        done = r
check("duplicate chunks do not corrupt the result", done == BIG,
      None if done is None else len(done))

check("a chunk for the wrong direction is ignored",
      client["collectChunk"]("request", "id", 1, 1, "x") is None)
check("a nonsense sequence number is ignored",
      client["collectChunk"]("response", "id", 0, 0, "x") is None)

print("== timeout control ==")
check("the default timeout is generous enough for local inference",
      client["getTimeout"]() >= 60, client["getTimeout"]())
client["setTimeout"](180)
check("setTimeout raises it", client["getTimeout"]() == 180, client["getTimeout"]())
client["setTimeout"](0)
check("setTimeout refuses a nonsense value", client["getTimeout"]() == 180,
      client["getTimeout"]())

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
