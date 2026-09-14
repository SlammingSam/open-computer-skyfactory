"""Exercise lib/env.lua and bin/update.lua against an in-memory filesystem.

The updater's whole promise is that it does NOT rewrite files it does not need
to, so the checks that matter are about what it leaves alone: unchanged files
must not be fetched or written at all, and /home/.env must survive no matter
what the repo contains.

Run:  pip install lupa && python tests/tools_harness.py
"""
import os.path
import sys
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# An in-memory filesystem plus a real (small) table serializer, so state
# genuinely round-trips through text the way it does on disk.
FS_PRELUDE = r"""
_G.__files = {}
_G.__writes = {}
_G.__fetched = {}

local function ser(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return string.format("%q", v)
  else
    return tostring(v)
  end
end

local function unser(s)
  local f = load("return " .. s)
  if not f then return nil end
  local ok, v = pcall(f)
  return ok and v or nil
end

io.open = function(path, mode)
  mode = mode or "r"
  if mode:find("r") then
    local content = _G.__files[path]
    if content == nil then return nil, "no such file: " .. tostring(path) end
    return {
      read = function(_, fmt) return content end,
      lines = function()
        local pos = 1
        return function()
          if pos > #content then return nil end
          local nl = content:find("\n", pos, true)
          local line
          if nl then line = content:sub(pos, nl - 1); pos = nl + 1
          else line = content:sub(pos); pos = #content + 1 end
          return line
        end
      end,
      close = function() end,
    }
  end
  local buf = {}
  if mode:find("a") and _G.__files[path] then buf[1] = _G.__files[path] end
  return {
    write = function(_, s) buf[#buf + 1] = s end,
    close = function()
      _G.__files[path] = table.concat(buf)
      _G.__writes[#_G.__writes + 1] = path
    end,
  }
end

local stubFs = {
  exists = function(p) return _G.__files[p] ~= nil end,
  makeDirectory = function() return true end,
  remove = function(p) _G.__files[p] = nil; return true end,
  rename = function(a, b) _G.__files[b] = _G.__files[a]; _G.__files[a] = nil; return true end,
  isDirectory = function() return false end,
  size = function(p) return #(_G.__files[p] or "") end,
  canonical = function(p) return p end,
  list = function() return function() return nil end end,
}

_G.__stubs = {
  filesystem = stubFs,
  serialization = { serialize = ser, unserialize = unser },
  component = {
    isAvailable = function(what) return what ~= "internet" end,
    internet = nil,
  },
  shell = { getWorkingDirectory = function() return "/home" end },
  event = { pull = function() return nil end },
}

require = function(name)
  if _G.__stubs[name] then return _G.__stubs[name] end
  error("no stub for " .. tostring(name))
end

os.sleep = function() end
"""


def new_runtime():
    lua = LuaRuntime(unpack_returned_tuples=False)
    lua.execute(FS_PRELUDE)
    lua.globals()["__libdir"] = os.path.join(ROOT, "lib").replace("\\", "/")
    return lua


failures = []


def check(name, cond, detail=""):
    if cond:
        print("  pass  " + name)
    else:
        print("  FAIL  " + name + ("  -> " + str(detail) if detail else ""))
        failures.append(name)


# ============================== lib/env.lua =================================

print("== env parsing ==")
lua = new_runtime()
env = lua.execute(open(os.path.join(ROOT, "lib", "env.lua"), encoding="utf-8").read())

lua.globals()["__files"]["/home/.env"] = "\n".join([
    "# a comment",
    "",
    "PROXY_ADDRESS=abc-123",
    '  QUOTED="hello world"  ',
    "SINGLE='tick'",
    "export EXPORTED=yes",
    "NUMERIC=8192",
    "TRAILING=value   # not part of it",
    "EMPTY=",
    "not a key line",
])

check("plain value", env.get("PROXY_ADDRESS") == "abc-123", env.get("PROXY_ADDRESS"))
check("double quotes are stripped", env.get("QUOTED") == "hello world", env.get("QUOTED"))
check("single quotes are stripped", env.get("SINGLE") == "tick", env.get("SINGLE"))
check("a leading export is allowed", env.get("EXPORTED") == "yes", env.get("EXPORTED"))
check("trailing comment is removed from an unquoted value",
      env.get("TRAILING") == "value", env.get("TRAILING"))
check("a blank value falls back to the default",
      env.get("EMPTY", "fallback") == "fallback", env.get("EMPTY", "fallback"))
check("a missing key falls back to the default",
      env.get("NOPE", "fallback") == "fallback")
check("numbers convert", env.number("NUMERIC", 0) == 8192, env.number("NUMERIC", 0))
check("a non-numeric value keeps the numeric default",
      env.number("QUOTED", 42) == 42, env.number("QUOTED", 42))
check("booleans read yes/true/on/1", env.bool("EXPORTED", False) is True)
check("a junk line does not break parsing", env.get("PROXY_ADDRESS") == "abc-123")

have, missing = env.present(lua.table_from(["PROXY_ADDRESS", "NOPE"]))
check("present() reports which keys exist",
      have[1] == "PROXY_ADDRESS" and missing[1] == "NOPE", (have[1], missing[1]))
check("present() returns names, never values",
      "abc-123" not in str([have[i] for i in range(1, len(have) + 1)]))

print("== env.set preserves the rest of the file ==")
env.set("PROXY_ADDRESS", "new-address")
written = lua.globals()["__files"]["/home/.env"]
check("the key is replaced", "PROXY_ADDRESS=new-address" in written)
check("the old value is gone", "abc-123" not in written)
check("comments survive", "# a comment" in written, written[:40])
check("other keys survive", "NUMERIC=8192" in written)
check("only one copy of the key exists", written.count("PROXY_ADDRESS=") == 1)

env.set("BRAND_NEW", "x")
written = lua.globals()["__files"]["/home/.env"]
check("a new key is appended", "BRAND_NEW=x" in written)
check("reading after set sees the new value",
      env.get("BRAND_NEW") == "x", env.get("BRAND_NEW"))

lua2 = new_runtime()
env2 = lua2.execute(open(os.path.join(ROOT, "lib", "env.lua"), encoding="utf-8").read())
check("a missing .env is not an error", env2.get("ANYTHING", "default") == "default")

# ============================= bin/update.lua ===============================

UPDATE_SRC = open(os.path.join(ROOT, "bin", "update.lua"), encoding="utf-8").read()
# Cut the CLI dispatch so nothing runs on load, and let the test supply argv.
UPDATE_SRC = UPDATE_SRC.split("-- =================================== cli ===")[0]
UPDATE_SRC = UPDATE_SRC.replace("local args = { ... }", "local args = _G.__args or {}")
UPDATE_SRC += """
return { run = run, installPathFor = installPathFor }
"""

TREE = {
    "lib/http.lua": ("sha-http-1", "http contents"),
    "lib/json.lua": ("sha-json-1", "json contents"),
    "bin/ollama.lua": ("sha-ollama-1", "ollama contents"),
    "diag/diag_job.lua": ("sha-diag-1", "diag contents"),
    "docs/OLLAMA.md": ("sha-docs-1", "docs contents"),
    "tests/harness.py": ("sha-tests-1", "test contents"),
    "README.md": ("sha-readme-1", "readme contents"),
    ".env": ("sha-env-1", "SECRET=leaked"),
}


def tree_json(entries):
    items = []
    for path, (sha, content) in entries.items():
        items.append('{"path":"%s","type":"blob","sha":"%s","size":%d}'
                     % (path, sha, len(content)))
    return '{"tree":[' + ",".join(items) + "]}"


def make_updater(lua, entries, args=(), short_read=None):
    """Wire a fake network that serves `entries`, then load update.lua."""
    lua.globals()["__args"] = lua.table_from(list(args))
    lua.execute("_G.__fetched = {}")

    payloads = {"TREE": tree_json(entries)}
    for path, (sha, content) in entries.items():
        payloads[path] = content
    lua.globals()["__payloads"] = lua.table_from(payloads)
    lua.globals()["__shortread"] = short_read or ""

    lua.execute(r"""
    _G.__stubs.http = {
      get = function(url)
        _G.__fetched[#_G.__fetched + 1] = url
        if url:find("api.github.com", 1, true) then
          return _G.__payloads["TREE"], nil, 200
        end
        local path = url:match("/main/(.+)$")
        local body = _G.__payloads[path]
        if body == nil then return nil, "404" end
        if path == _G.__shortread then return body:sub(1, 2), nil, 200 end
        return body, nil, 200
      end,
      setTimeout = function() end,
    }
    """)
    # update.lua finds modules through loadfile; serve the real lib/ files.
    lua.execute(r"""
    local realLoadfile = loadfile
    loadfile = function(path)
      if type(path) ~= "string" then return nil end
      local name = path:match("([%w_]+)%.lua$")
      if name == "http" then return function() return _G.__stubs.http end end
      if name then return realLoadfile(_G.__libdir .. "/" .. name .. ".lua") end
      return nil
    end
    """)
    return lua.execute(UPDATE_SRC)


def fileat(lua, path):
    return lua.globals()["__files"][path]


def written_paths(lua):
    w = lua.globals()["__writes"]
    return [w[i] for i in range(1, len(w) + 1)]


def reset_writes(lua):
    lua.execute("_G.__writes = {}")


def fetched(lua):
    f = lua.globals()["__fetched"]
    return [f[i] for i in range(1, len(f) + 1)]


print("== which repo paths get installed ==")
lua = new_runtime()
upd = make_updater(lua, TREE)
ip = upd["installPathFor"]
check("lib/ goes to /home/lib/", ip("lib/http.lua") == "/home/lib/http.lua", ip("lib/http.lua"))
check("bin/ goes to /home/bin/", ip("bin/ollama.lua") == "/home/bin/ollama.lua")
check("diag/ goes to /home/diag/", ip("diag/diag_job.lua") == "/home/diag/diag_job.lua")
check("docs/ is not installed by default", ip("docs/OLLAMA.md") is None)
check("tests/ is never installed", ip("tests/harness.py") is None)
check("root files are not installed", ip("README.md") is None)

print("== first run installs everything tracked ==")
lua = new_runtime()
upd = make_updater(lua, TREE)
upd["run"]()
paths = written_paths(lua)
check("library files were written", "/home/lib/http.lua" in paths, paths)
check("programs were written", "/home/bin/ollama.lua" in paths)
check("diagnostics were written", "/home/diag/diag_job.lua" in paths)
check("docs were skipped", "/home/docs/OLLAMA.md" not in paths)
check("the state file was saved",
      fileat(lua, "/home/.update_state") is not None)
check("contents landed intact",
      lua.globals()["__files"]["/home/bin/ollama.lua"] == "ollama contents")

print("== .env is never touched ==")
check("a repo .env is not installed over the local one",
      "/home/.env" not in paths, paths)
check("nothing from the repo landed on /home/.env",
      fileat(lua, "/home/.env") is None, fileat(lua, "/home/.env"))

print("== second run rewrites nothing ==")
reset_writes(lua)
lua.execute("_G.__fetched = {}")
upd["run"]()
paths = written_paths(lua)
check("no program file was rewritten",
      not any(p.startswith("/home/bin/") or p.startswith("/home/lib/") for p in paths),
      paths)
check("unchanged files were not even downloaded",
      len([u for u in fetched(lua) if "raw.githubusercontent" in u]) == 0,
      fetched(lua))
check("only the tree listing was fetched",
      len(fetched(lua)) == 1, fetched(lua))

print("== only the changed file is refetched ==")
CHANGED = dict(TREE)
CHANGED["bin/ollama.lua"] = ("sha-ollama-2", "ollama contents v2")
lua.globals()["__payloads"]["TREE"] = tree_json(CHANGED)
lua.globals()["__payloads"]["bin/ollama.lua"] = "ollama contents v2"
reset_writes(lua)
lua.execute("_G.__fetched = {}")
upd["run"]()
paths = written_paths(lua)
downloads = [u for u in fetched(lua) if "raw.githubusercontent" in u]
check("exactly one file was downloaded", len(downloads) == 1, downloads)
check("it was the changed one", downloads and downloads[0].endswith("bin/ollama.lua"),
      downloads)
check("the new contents were written",
      lua.globals()["__files"]["/home/bin/ollama.lua"] == "ollama contents v2")
check("the untouched library file was not rewritten",
      "/home/lib/http.lua" not in paths, paths)

print("== a locally missing file comes back ==")
lua.execute('_G.__files["/home/lib/json.lua"] = nil')
reset_writes(lua)
lua.execute("_G.__fetched = {}")
upd["run"]()
downloads = [u for u in fetched(lua) if "raw.githubusercontent" in u]
check("a deleted local file is re-downloaded even with an unchanged sha",
      len(downloads) == 1 and downloads[0].endswith("lib/json.lua"), downloads)
check("it is restored", lua.globals()["__files"]["/home/lib/json.lua"] == "json contents")

print("== a truncated download does not count as done ==")
lua2 = new_runtime()
upd2 = make_updater(lua2, TREE, short_read="lib/http.lua")
upd2["run"]()
check("the short file was not written",
      fileat(lua2, "/home/lib/http.lua") is None,
      fileat(lua2, "/home/lib/http.lua"))
check("other files still installed",
      lua2.globals()["__files"]["/home/bin/ollama.lua"] == "ollama contents")

# The failure must not be recorded, so the next run retries it.
lua2.execute("_G.__shortread = ''")
lua2.execute("_G.__fetched = {}")
upd2["run"]()
downloads = [u for u in fetched(lua2) if "raw.githubusercontent" in u]
check("the failed file is retried on the next run",
      any(u.endswith("lib/http.lua") for u in downloads), downloads)
check("and then succeeds",
      lua2.globals()["__files"]["/home/lib/http.lua"] == "http contents")

print("== --all and --force ==")
lua3 = new_runtime()
upd3 = make_updater(lua3, TREE, args=["--all"])
upd3["run"]()
check("--all installs docs", lua3.globals()["__files"]["/home/docs/OLLAMA.md"] == "docs contents")

lua4 = new_runtime()
upd4 = make_updater(lua4, TREE)
upd4["run"]()
reset_writes(lua4)
lua4.execute("_G.__fetched = {}")
lua4.globals()["__args"] = lua4.table_from(["--force"])
upd4b = make_updater(lua4, TREE, args=["--force"])
upd4b["run"]()
downloads = [u for u in fetched(lua4) if "raw.githubusercontent" in u]
check("--force re-downloads everything tracked", len(downloads) >= 4, len(downloads))

print("== --list changes nothing ==")
lua5 = new_runtime()
upd5 = make_updater(lua5, TREE, args=["--list"])
upd5["run"]()
check("--list writes no files",
      fileat(lua5, "/home/bin/ollama.lua") is None,
      written_paths(lua5))
check("--list does not even save state",
      fileat(lua5, "/home/.update_state") is None)

print()
if failures:
    print("%d FAILURES: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
