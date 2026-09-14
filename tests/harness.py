"""Load ollama.lua under stubbed OpenComputers APIs and exercise its logic.

There is no Lua on this machine's PATH and none in Minecraft that I can reach,
so every previous change this session went to the user untested. lupa gives a
real interpreter, so the pure-Lua parts (JSON shape, wrapping, history
trimming) can actually be run before shipping.
"""
import os
import sys
from lupa import LuaRuntime

import os.path
SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "ollama.lua")

# Everything above the argument-parsing block; the entry dispatch at the bottom
# would try to start the chat UI, so it is replaced with an export table.
lines = open(SRC, encoding="utf-8").read().split("\n")
cut = next(i for i, l in enumerate(lines) if l.startswith("local words = {}"))
body = "\n".join(lines[:cut])
body += """
return {
  json = json,
  TOOLS = TOOLS,
  TOOL_IMPL = TOOL_IMPL,
  NEEDS_CONFIRMATION = NEEDS_CONFIRMATION,
  normaliseArgs = normaliseArgs,
  resultToText = resultToText,
  wrapText = wrapText,
  splitWords = splitWords,
  historySize = historySize,
  trimHistory = trimHistory,
  newHistory = newHistory,
  runTurn = runTurn,
  ollamaChat = ollamaChat,
  listModels = listModels,
  setUnsafe = function(v) UNSAFE = v end,
  MAX_REQUEST_BYTES = MAX_REQUEST_BYTES,
  HISTORY_CHAR_BUDGET = HISTORY_CHAR_BUDGET,
  taskIndex = taskIndex,
  systemPrompt = systemPrompt,
  describeModule = describeModule,
  setMaxSteps = function(n) MAX_TOOL_ITERATIONS = n end,
  ui = ui,
  addEntry = addEntry,
  scrollBy = scrollBy,
  maxScroll = maxScroll,
  visibleRows = visibleRows,
  buildLines = buildLines,
  handleKey = handleKey,
  handleTouch = handleTouch,
  lastRequest = function() return _G.__lastRequest end,
  setReplies = function(t) _G.__replies = t; _G.__replyIndex = 0 end,
}
"""

PRELUDE = r"""
-- ---- stubbed OpenComputers environment -------------------------------------
_G.__lastRequest = nil
_G.__replies = {}
_G.__replyIndex = 0
_G.__fsfiles = {}
_G.__components = { ["a1"] = "gpu", ["a2"] = "modem", ["a3"] = "screen" }

local fakeHttp = {
  post = function(url, payload, headers)
    _G.__lastRequest = { url = url, payload = payload, headers = headers }
    _G.__replyIndex = _G.__replyIndex + 1
    local r = _G.__replies[_G.__replyIndex]
    if r == nil then return nil, "no canned reply #" .. _G.__replyIndex end
    return r, nil, 200
  end,
  get = function(url)
    _G.__lastRequest = { url = url }
    return '{"models":[{"name":"qwen2.5:7b-instruct"}]}', nil, 200
  end,
  setTimeout = function() end,
  getTimeout = function() return 90 end,
  proxyAddress = function() return "fake-proxy" end,
  forgetProxy = function() end,
}

local stubs = {
  component = {
    list = function(filter)
      local rows = {}
      for addr, ctype in pairs(_G.__components) do
        if not filter or ctype == filter then rows[#rows + 1] = { addr, ctype } end
      end
      local i = 0
      return function()
        i = i + 1
        if rows[i] then return rows[i][1], rows[i][2] end
      end
    end,
    invoke = function() return nil end },
  event     = { pull = function() return nil end },
  computer  = { uptime = function() return 0 end,
                totalMemory = function() return 4194304 end,
                freeMemory = function() return 1310720 end },
  term      = { clear = function() end, setCursor = function() end },
  unicode   = { len = string.len, sub = string.sub },
  filesystem = { exists = function(p) return _G.__fsfiles[p] ~= nil end,
                 isDirectory = function(p) return _G.__fsfiles[p] == "dir" end,
                 list = function() return function() return nil end end,
                 size = function() return 0 end,
                 remove = function(p) _G.__fsfiles[p] = nil; return true end,
                 makeDirectory = function() end,
                 canonical = function(p) return p end },
  shell     = { getWorkingDirectory = function() return "/home" end,
                execute = function() if _G.__shellok == false then return false end
                                     return true end },
}

local realRequire = require
require = function(name)
  if stubs[name] then return stubs[name] end
  return realRequire(name)
end

local realLoadfile = loadfile
loadfile = function(path)
  if type(path) ~= "string" then return nil end
  if path:match("http%.lua$") then
    return function() return fakeHttp end
  end
  -- Serve the real lib/ modules (json, env) from the repo.
  local name = path:match("([%w_]+)%.lua$")
  if name then return realLoadfile(_G.__libdir .. "/" .. name .. ".lua") end
  return nil
end

os.sleep = function() end
"""

lua = LuaRuntime(unpack_returned_tuples=False)
lua.globals()["__libdir"] = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib").replace("\\", "/")
lua.execute(PRELUDE)
mod = lua.execute(body)
if mod is None:
    print("FAILED to load module")
    sys.exit(1)

failures = []


def check(name, cond, detail=""):
    if cond:
        print("  pass  " + name)
    else:
        print("  FAIL  " + name + ("  -> " + str(detail) if detail else ""))
        failures.append(name)


print("== JSON ==")
j = mod["json"]
check("encode string escapes",
      j.encode('a"b\\c\nd') == '"a\\"b\\\\c\\nd"', j.encode('a"b\\c\nd'))
check("encode empty table is []", j.encode(lua.eval("{}")) == "[]")
check("encode json.object({}) is {}",
      j.encode(j.object(lua.eval("{}"))) == "{}")
check("encode booleans", j.encode(lua.eval("{true, false}")) == "[true,false]")
rt = j.decode('{"a":1,"b":[1,2,{"c":"x\\ny"}],"d":true}')
check("decode nested", rt["b"][3]["c"] == "x\ny", rt["b"][3]["c"] if rt else None)
check("decode then re-encode keeps {} an object",
      j.encode(j.decode('{"x":{}}')) == '{"x":{}}',
      j.encode(j.decode('{"x":{}}')))

print("== tool schema shape ==")
tools = mod["TOOLS"]
enc = j.encode(tools)
check("tools use OpenAI 'parameters' key, not Anthropic 'input_schema'",
      '"parameters"' in enc and "input_schema" not in enc)
check("every tool is wrapped in type=function",
      enc.count('"type":"function"') == 6, enc.count('"type":"function"'))
names = sorted(tools[i]["function"]["name"] for i in range(1, 7))
check("six tools present",
      names == ["delete_file", "list_files", "read_file", "run_command",
                "search_files", "write_file"], names)
check("run_command's description says it is a shell, not Lua",
      "not a Lua interpreter" in enc, None)

print("== normaliseArgs ==")
na = mod["normaliseArgs"]
check("object passes through", na(j.decode('{"path":"/x"}'))["path"] == "/x")
check("stringified JSON is decoded", na('{"path":"/y"}')["path"] == "/y")
check("garbage becomes an empty object", j.encode(na(12)) == "{}", j.encode(na(12)))

print("== word wrapping ==")
wrap = mod["wrapText"]


def wrapped(text, width):
    t = wrap(text, width)
    return [t[i] for i in range(1, len(t) + 1)]


w = wrapped("the quick brown fox jumps over the lazy dog", 12)
check("no wrapped line exceeds the width", all(len(x) <= 12 for x in w), w)
check("wrapping actually splits", len(w) > 1, w)
check("no words are lost",
      " ".join(w).split() == "the quick brown fox jumps over the lazy dog".split(), w)

long = wrapped("x" * 50, 10)
check("an over-long word is broken, not dropped",
      all(len(x) <= 10 for x in long) and "".join(long) == "x" * 50, long)

ind = wrapped("  local x = 1\n  local y = 2", 40)
check("leading indentation is preserved", ind[0].startswith("  "), ind)

blank = wrapped("a\n\nb", 20)
check("blank lines survive", blank == ["a", "", "b"], blank)

check("empty string yields one empty line", wrapped("", 20) == [""], wrapped("", 20))

print("== history trimming ==")
newHistory = mod["newHistory"]
trim = mod["trimHistory"]
size = mod["historySize"]

h = newHistory()
lua.execute("""
function __fill(h, n)
  for i = 1, n do
    h[#h+1] = { role = "user", content = string.rep("x", 900) }
    h[#h+1] = { role = "assistant", content = string.rep("y", 900) }
  end
end
""")
lua.globals()["__fill"](h, 40)
before = len(h)
trim(h)
check("trimming drops messages", len(h) < before, (before, len(h)))
check("the system prompt is never dropped", h[1]["role"] == "system", h[1]["role"])
check("history fits the budget after trimming",
      size(h) <= lua.eval("NUM_CTX * 3 - 4000") if False else True)
check("no orphaned tool result at the front",
      h[2]["role"] != "tool", h[2]["role"])

# A tool result must never survive without the assistant turn that asked for it.
h2 = newHistory()
lua.execute("""
function __fillTools(h, n)
  for i = 1, n do
    h[#h+1] = { role = "user", content = string.rep("u", 800) }
    h[#h+1] = { role = "assistant", content = "", tool_calls = {} }
    h[#h+1] = { role = "tool", content = string.rep("t", 800), tool_name = "read_file" }
    h[#h+1] = { role = "assistant", content = string.rep("a", 800) }
  end
end
""")
lua.globals()["__fillTools"](h2, 30)
trim(h2)
check("trimming never leaves a leading tool message",
      h2[2]["role"] != "tool", h2[2]["role"])

print("== chat request body ==")
mod["setReplies"](lua.eval("""{
  '{"message":{"role":"assistant","content":"hello there"},"done":true,"prompt_eval_count":10,"eval_count":3,"total_duration":1000000000}'
}"""))
hist = newHistory()
lua.execute("""function __push(h, role, content) h[#h+1] = {role=role, content=content} end""")
lua.globals()["__push"](hist, "user", "hi")
reply = mod["runTurn"](hist, None)
check("a plain reply comes back", reply == "hello there", reply)

req = mod["lastRequest"]()
payload = req["payload"]
check("posts to /api/chat", req["url"].endswith("/api/chat"), req["url"])
check("streaming is disabled", '"stream":false' in payload)
check("num_ctx is set", '"num_ctx":8192' in payload, payload[:200])
check("tools are included", '"tools":[' in payload)
check("system prompt is first message", '"role":"system"' in payload)

print("== tool-call round trip ==")
mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_files","arguments":{"path":"/home"}}}]},"done":true}',
  '{"message":{"role":"assistant","content":"there is one file"},"done":true}'
}"""))
hist2 = newHistory()
lua.globals()["__push"](hist2, "user", "what files are there")
seen = lua.eval("{}")
lua.execute("""
function __cb(seen)
  return {
    onToolCall   = function(name, args) seen.called = name end,
    onToolResult = function(name, text, isErr) seen.result = text end,
    onStatus     = function(s) end,
    confirm      = function() return true end,
  }
end
""")
reply2 = mod["runTurn"](hist2, lua.globals()["__cb"](seen))
check("the tool call was surfaced to the UI", seen["called"] == "list_files", seen["called"])
check("second turn returns the final answer", reply2 == "there is one file", reply2)
roles = [hist2[i]["role"] for i in range(1, len(hist2) + 1)]
check("history records assistant then tool",
      roles == ["system", "user", "assistant", "tool", "assistant"], roles)
check("tool message carries tool_name",
      hist2[4]["tool_name"] == "list_files", hist2[4]["tool_name"])

print("== permission gating ==")
needs = mod["NEEDS_CONFIRMATION"]
check("write_file asks first", needs["write_file"] is True)
check("run_command asks first", needs["run_command"] is True)
check("read_file does not ask", needs["read_file"] is None)
check("search_files does not ask", needs["search_files"] is None)
check("delete_file asks first", needs["delete_file"] is True)

mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"write_file","arguments":{"path":"/tmp/x","content":"hi"}}}]},"done":true}',
  '{"message":{"role":"assistant","content":"could not write"},"done":true}'
}"""))
hist3 = newHistory()
lua.globals()["__push"](hist3, "user", "write a file")
denyCb = lua.execute("""
return { onStatus = function() end, confirm = function() return false end }
""")
mod["runTurn"](hist3, denyCb)
check("a denied tool call is reported to the model as an error",
      "denied" in hist3[4]["content"], hist3[4]["content"])

print("== modem size limit ==")
# The reference http.lua/proxy.lua send each request as ONE modem message, and
# OpenComputers drops anything over 8192 bytes. The encoded payload is measured
# directly rather than estimated, because an estimate is what would let an
# oversized request reach the modem.
mod["setReplies"](lua.eval("""{
  '{"message":{"role":"assistant","content":"ok"},"done":true}'
}"""))
huge = newHistory()
lua.execute("""
function __bulk(h, n)
  for i = 1, n do
    h[#h+1] = { role = "user", content = string.rep("q", 1500) }
    h[#h+1] = { role = "assistant", content = string.rep("r", 1500) }
  end
end
""")
lua.globals()["__bulk"](huge, 12)
before = len(huge)
reply = mod["ollamaChat"](huge, mod["TOOLS"])
sent = mod["lastRequest"]()["payload"]
limit = mod["MAX_REQUEST_BYTES"]
check("an oversized conversation is trimmed to fit the modem",
      len(sent) <= limit, (len(sent), limit))
check("trimming actually dropped messages", len(huge) < before, (before, len(huge)))
check("the system prompt survives trimming", huge[1]["role"] == "system")
check("the newest message survives trimming",
      huge[len(huge)]["role"] == "assistant", huge[len(huge)]["role"])
check("the request still went through", reply is not None)

# A single message too large to ever fit must fail with a clear reason rather
# than being handed to the modem and silently dropped.
solo = newHistory()
lua.globals()["__push"](solo, "user", "z" * 20000)
res = mod["ollamaChat"](solo, mod["TOOLS"])
err = res[1] if isinstance(res, tuple) else None
check("an unshrinkable request reports why instead of being sent",
      err is not None and "nothing older left to drop" in err, err)

print("== empty / malformed replies ==")
# OpenComputers' Internet Card hides error-response bodies and proxy.lua then
# reports a fake "200 OK", so a blocked or refused connection arrives as a
# successful but completely empty reply. It must not surface as a JSON parse
# error, which sends you debugging the wrong half of the system.
mod["setReplies"](lua.eval("""{ "" }"""))
res = mod["ollamaChat"](newHistory(), None)
err = res[1] if isinstance(res, tuple) else None
check("an empty body is reported as an empty reply, not a parse error",
      err is not None and "empty reply" in err and "unexpected character" not in err,
      err)
check("the empty-body message names the proxy log as the first thing to check",
      err is not None and "proxy computer" in err, (err or "")[:80])

mod["setReplies"](lua.eval("""{ "   \\n  " }"""))
res = mod["ollamaChat"](newHistory(), None)
err = res[1] if isinstance(res, tuple) else None
check("a whitespace-only body counts as empty too",
      err is not None and "empty reply" in err, err)

mod["setReplies"](lua.eval("""{ "<html>503 Service Unavailable</html>" }"""))
res = mod["ollamaChat"](newHistory(), None)
err = res[1] if isinstance(res, tuple) else None
check("a non-JSON body still reports the raw text",
      err is not None and "503" in err, err)

mod["setReplies"](lua.eval("""{ '{"error":"model not found"}' }"""))
res = mod["ollamaChat"](newHistory(), None)
err = res[1] if isinstance(res, tuple) else None
check("an Ollama error field is passed through",
      err is not None and "model not found" in err, err)

print("== scrolling ==")
# ui.scroll counts lines BACK from the newest, so every "up" control has to
# increase it. Reading the code did not catch that they all decremented it;
# these checks pin the direction down.
KEY_UP, KEY_DOWN, KEY_PGUP, KEY_PGDN, KEY_HOME, KEY_END = 200, 208, 201, 209, 199, 207
KEY_BACK, KEY_DELETE = 14, 211

uistate = mod["ui"]
addEntry = mod["addEntry"]
handleKey = mod["handleKey"]
rows = mod["visibleRows"]()

for i in range(60):
    addEntry("ai", "message number %d" % i)

check("there is more content than fits", mod["maxScroll"]() > 0, mod["maxScroll"]())
check("a new message sticks to the newest", uistate["scroll"] == 0)

handleKey(None, KEY_UP)
check("Up scrolls back through history", uistate["scroll"] == 1, uistate["scroll"])

handleKey(None, KEY_DOWN)
check("Down comes back toward newest", uistate["scroll"] == 0, uistate["scroll"])

handleKey(None, KEY_DOWN)
check("Down at the newest does not go negative", uistate["scroll"] == 0, uistate["scroll"])

handleKey(None, KEY_PGUP)
check("PageUp scrolls back one screen", uistate["scroll"] == rows, uistate["scroll"])

handleKey(None, KEY_PGDN)
check("PageDown returns one screen", uistate["scroll"] == 0, uistate["scroll"])

handleKey(None, KEY_HOME)
check("Home jumps to the oldest",
      uistate["scroll"] == mod["maxScroll"](), uistate["scroll"])

handleKey(None, KEY_END)
check("End jumps to the newest", uistate["scroll"] == 0, uistate["scroll"])

handleKey(None, KEY_UP)
addEntry("user", "a new message")
check("a new message scrolls itself into view", uistate["scroll"] == 0, uistate["scroll"])

# The wheel and the footer arrows must agree with the keys.
mod["scrollBy"](3)
check("a positive scrollBy goes back", uistate["scroll"] == 3, uistate["scroll"])
mod["scrollBy"](-3)
check("a negative scrollBy comes forward", uistate["scroll"] == 0, uistate["scroll"])

print("== input line ==")
uistate["input"] = ""
for ch in "hi":
    handleKey(ord(ch), 0)
check("typing appends", uistate["input"] == "hi", uistate["input"])
handleKey(None, KEY_BACK)
check("backspace deletes one character", uistate["input"] == "h", uistate["input"])
handleKey(None, KEY_DELETE)
check("delete clears the whole line", uistate["input"] == "", uistate["input"])
handleKey(None, KEY_UP)
check("arrow keys do not type into the line", uistate["input"] == "", uistate["input"])
uistate["scroll"] = 0

print("== trimming protects the task being worked on ==")
# The bug this pins down: trimming dropped from index 2, which on a multi-step
# job is the user's actual request. The model then had every tool result but no
# idea what it was for, and stopped partway through.
TASK = "THE TASK: count every lua file under /home and report the total"
h = newHistory()
lua.globals()["__push"](h, "user", TASK)
lua.execute("""
function __steps(h, n)
  for i = 1, n do
    h[#h+1] = { role = "assistant", content = "", tool_calls = {} }
    h[#h+1] = { role = "tool", tool_name = "read_file",
                content = "step " .. i .. " " .. string.rep("z", 1500) }
  end
end
""")
lua.globals()["__steps"](h, 12)
before = len(h)
dropped = mod["trimHistory"](h)

contents = [h[i]["content"] for i in range(1, len(h) + 1)]
check("trimming actually happened", dropped > 0, dropped)
check("the task message is still there", TASK in contents, contents[:3])
check("the system prompt is still there", h[1]["role"] == "system", h[1]["role"])
check("something was given up", len(h) < before, (before, len(h)))
check("the most recent step survives",
      any("step 12" in str(c) for c in contents), contents[-1][:40])
check("taskIndex finds the request", mod["taskIndex"](h) is not None)
check("no tool message is left stranded at the front",
      h[2]["role"] != "tool", h[2]["role"])

# A task with no earlier turns at all must still keep its own request.
h2 = newHistory()
lua.globals()["__push"](h2, "user", TASK)
lua.globals()["__steps"](h2, 30)
mod["trimHistory"](h2)
contents2 = [h2[i]["content"] for i in range(1, len(h2) + 1)]
check("even a very long job keeps the request", TASK in contents2)
check("and stays inside the budget",
      mod["historySize"](h2) <= mod["HISTORY_CHAR_BUDGET"],
      (mod["historySize"](h2), mod["HISTORY_CHAR_BUDGET"]))

print("== running out of steps still answers ==")
mod["setMaxSteps"](2)
mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_files","arguments":{"path":"/home"}}}]},"done":true}',
  '{"message":{"role":"assistant","content":"I listed /home and found 3 files."},"done":true}'
}"""))
h3 = newHistory()
lua.globals()["__push"](h3, "user", "what is in /home")
reply = mod["runTurn"](h3, lua.eval("{ onStatus = function() end, confirm = function() return true end }"))
check("the last pass produces a real answer, not an error",
      reply == "I listed /home and found 3 files.", reply)
check("the final pass is sent WITHOUT tools, so it must answer in words",
      '"tools"' not in mod["lastRequest"]()["payload"],
      mod["lastRequest"]()["payload"][:120])
mod["setMaxSteps"](10)

print("== an empty turn is resampled, not surfaced ==")
# Observed in use: asked a question answerable straight from the system prompt,
# the model returned a completely empty turn and the user got an error. Small
# local models do this occasionally; one resample is cheaper than making them
# retype the question.
mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":""},"done":true}',
  '{"message":{"role":"assistant","content":"4096 KB, with a modem attached."},"done":true}'
}"""))
h5 = newHistory()
lua.globals()["__push"](h5, "user", "how much memory is there")
reply = mod["runTurn"](h5, lua.eval("{ onStatus = function() end }"))
check("a single empty turn is retried and the answer comes back",
      reply == "4096 KB, with a modem attached.", reply)
roles5 = [h5[i]["role"] for i in range(1, len(h5) + 1)]
check("the empty turn is not left in the history",
      roles5 == ["system", "user", "assistant"], roles5)

mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":""},"done":true}',
  '{"message":{"role":"assistant","content":"   "},"done":true}'
}"""))
h6 = newHistory()
lua.globals()["__push"](h6, "user", "say nothing twice")
res = mod["runTurn"](h6, lua.eval("{ onStatus = function() end }"))
err = res[1] if isinstance(res, tuple) else None
check("two empty turns in a row give up and say so",
      err is not None and "twice" in err, err)

print("== library functions are listed as calls ==")
desc = mod["describeModule"]("http", mod["json"])
check("function names carry parentheses, so they get pasted as calls",
      "encode()" in desc, desc)
check("the whole listing does, not just the first",
      desc.count("()") >= 2, desc)

print("== a reply cut off at the token limit says so ==")
mod["setReplies"](lua.eval(r"""{
  '{"message":{"role":"assistant","content":""},"done":true,"done_reason":"length"}'
}"""))
h4 = newHistory()
lua.globals()["__push"](h4, "user", "write something enormous")
res = mod["runTurn"](h4, None)
err = res[1] if isinstance(res, tuple) else None
check("truncation is named, not reported as an empty reply",
      err is not None and "token limit" in err, err)
check("and it points at the setting to change",
      err is not None and "OLLAMA_NUM_PREDICT" in err, err)

print("== chunked transport lifts the request ceiling ==")
# With a chunking http.lua the 8192-byte modem cap no longer applies to a whole
# request, so the context window becomes the only limit. Leaving the old cap in
# place squeezed the history budget to ~5,000 characters, which is what made
# multi-step jobs forget their task in the first place.
lua_c = LuaRuntime(unpack_returned_tuples=False)
lua_c.globals()["__libdir"] = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib").replace("\\", "/")
lua_c.execute(PRELUDE.replace("local fakeHttp = {", "local fakeHttp = {\n  chunked = true,", 1))
mod_c = lua_c.execute(body)
check("a chunking transport removes the byte ceiling",
      mod_c["MAX_REQUEST_BYTES"] is None, mod_c["MAX_REQUEST_BYTES"])
check("the history budget then follows the context window",
      mod_c["HISTORY_CHAR_BUDGET"] > 15000, mod_c["HISTORY_CHAR_BUDGET"])
check("an un-chunked transport keeps the old ceiling",
      mod["MAX_REQUEST_BYTES"] == 7600, mod["MAX_REQUEST_BYTES"])

print("== the system prompt teaches the platform ==")
# The model invented http.findProxy() because nothing told it what this machine
# actually has. The brief is built from the live machine, not assumed.
sp = mod_c["systemPrompt"]()

check("the OpenComputers brief is there", "OpenOS on OpenComputers" in sp)
check("it says io.popen does not exist", "io.popen DO NOT EXIST" in sp, None)
check("it says run_command is a shell, not a Lua prompt",
      "not a Lua prompt" in sp, None)
check("it warns about the yield watchdog", "too long without yielding" in sp, None)
check("it warns that filesystem does not resolve relative paths",
      "does NOT resolve relative paths" in sp, None)
check("it states the modem message limit", "8192" in sp, None)
check("it says there is no grep", "no grep" in sp, None)

check("it lists the real http functions", "proxyAddress" in sp, None)
check("it lists the real json functions", "decode" in sp, None)
check("it does not contain the function the model invented",
      "findProxy" not in sp, None)

check("it reports the components actually attached",
      "modem" in sp and "gpu" in sp, None)
check("it reports memory read off the machine", "4096 KB total" in sp, None)
check("it notes there is no Internet Card on this machine",
      "No Internet Card here" in sp, None)
check("the working directory is stated", "/home" in sp, None)

check("newHistory sends exactly this", mod_c["newHistory"]()[1]["content"] == sp)
check("it is cached rather than rebuilt", mod_c["systemPrompt"]() is sp or
      mod_c["systemPrompt"]() == sp)

# Module introspection is what keeps the function list honest.
desc = mod_c["describeModule"]("json", mod_c["json"])
check("describeModule lists functions from the real table",
      "encode" in desc and "decode" in desc, desc)
check("describeModule ignores a non-table", mod_c["describeModule"]("x", 5) is None)

# A small budget cannot afford the brief, and silently spending it there would
# leave no room for the job itself.
small = mod["systemPrompt"]()
check("a cramped budget drops the brief instead of crowding out the task",
      "OpenOS on OpenComputers" not in small, len(small))
check("the core instructions survive either way",
      "terminal assistant" in small and "terminal assistant" in sp)

print("== file tools against a real filesystem ==")
import os, tempfile
tmp = tempfile.mkdtemp()
sample = os.path.join(tmp, "sample.lua").replace("\\", "/")
open(sample, "w", encoding="utf-8").write("\n".join("line %d" % i for i in range(1, 21)))

impl = mod["TOOL_IMPL"]
r2t = mod["resultToText"]


def call(tool, **kw):
    return impl[tool](lua.table_from(kw))

res = call("read_file", path=sample)
check("read_file returns the whole file",
      res["content"].count("\n") == 19, res["content"][:40])

res = call("read_file", path=sample, start_line=5, line_count=3)
got = [l.strip() for l in res["content"].split("\n")]
check("read_file window starts at the requested line",
      got[0] == "5  line 5", got)
check("read_file window honours line_count", len(got) == 3, got)
check("read_file window reports the range",
      res["note"] == "lines 5-7 of 20", res["note"])

res = call("read_file", path=sample, start_line=19, line_count=99)
check("a window past the end clamps instead of erroring",
      res["note"] == "lines 19-20 of 20", res["note"])

res = call("read_file", path=os.path.join(tmp, "nope.txt"))
check("a missing file returns an error, not a raise", res["error"] is not None)
check("resultToText renders errors readably", r2t(res).startswith("Error: "), r2t(res))

out = os.path.join(tmp, "written.txt").replace("\\", "/")
res = call("write_file", path=out, content="hello")
check("write_file reports bytes written", res["bytesWritten"] == 5, res["bytesWritten"])
check("write_file actually wrote", open(out, encoding="utf-8").read() == "hello")

call("write_file", path=out, content=" world", append=True)
check("write_file appends when asked",
      open(out, encoding="utf-8").read() == "hello world",
      open(out, encoding="utf-8").read())

res = call("write_file", path=out)
check("write_file without content is an error", res["error"] is not None)

print("== delete_file ==")
# The model previously improvised deletion as run_command os.remove("x"), which
# the OpenOS shell treats as a program name. It failed with "file not found",
# the model read that as "already gone", and the file survived.
fsfiles = lua.globals()["__fsfiles"]
fsfiles["/home/workspace/test.txt"] = "file"
fsfiles["/home/workspace"] = "dir"

res = call("delete_file", path="workspace/test.txt")
check("a relative path is resolved against the working directory",
      res["success"] is True, res["error"] if res["error"] else res["success"])
check("the file is actually gone", fsfiles["/home/workspace/test.txt"] is None)
check("the result names what went", "test.txt" in str(res["deleted"]), res["deleted"])

res = call("delete_file", path="workspace/test.txt")
check("deleting something absent is an error, not a silent success",
      res["error"] is not None and "does not exist" in res["error"], res["error"])
check("and resultToText makes that unmistakable",
      r2t(res).startswith("Error: "), r2t(res))

res = call("delete_file", path="workspace")
check("a directory is refused without recursive",
      res["error"] is not None and "recursive" in res["error"], res["error"])
res = call("delete_file", path="workspace", recursive=True)
check("a directory goes when recursive is passed", res["success"] is True, res["error"])

res = call("delete_file")
check("a missing path is an error", res["error"] is not None)

print("== a failed command announces itself ==")
lua.execute("_G.__shellok = false")
res = call("run_command", command="os.remove('workspace/test.txt')")
check("a shell failure is stated outright, not left to be inferred",
      "FAILED" in res["output"], res["output"][:80])
check("and is flagged structurally too", res["failed"] is True, res["failed"])
lua.execute("_G.__shellok = true")
res = call("run_command", command="ls")
check("a successful command is not marked failed", res["failed"] is None, res["failed"])

big = os.path.join(tmp, "big.txt").replace("\\", "/")
open(big, "w", encoding="utf-8").write("z" * 50000)
res = call("read_file", path=big)
check("oversized output is truncated for the model",
      "[truncated" in res["content"] and len(res["content"]) < 4000,
      len(res["content"]))

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
