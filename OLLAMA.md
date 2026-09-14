# ollama.lua — local LLM chat with tool access, in-game

A chat client for a **local Ollama instance**, running on an OpenComputers
terminal. It has Claude Code–style tool access to the computer it runs on: it
can read files, write files, list directories, search a directory tree, and run
shell commands, deciding for itself when to use them.

All network traffic goes through `http.lua` → `proxy.lua`, exactly like
`claude.lua`. This computer needs only a **Network Card**; the Internet Card
lives on the proxy machine.

```
OC terminal ──modem──► proxy.lua ──Internet Card──► http://<host>:11434/api/chat
 (ollama.lua)                                        (your GPU box)
```

---

## Which model

Your box is a **GTX 1070 Ti (8 GB VRAM)** with 16 GB system RAM. The whole
model plus its KV cache has to fit in those 8 GB, or llama.cpp spills into
system RAM and generation speed falls off a cliff.

**Recommended: `qwen2.5:7b-instruct`**

```bash
ollama pull qwen2.5:7b-instruct
```

- Q4_K_M weights are ~4.7 GB, leaving comfortable room for the 8192-token
  context this client asks for.
- First-class tool-calling support in Ollama, which is the whole point here —
  a model that ignores the `tools` parameter makes this app a plain chatbot.
- Strong instruction following for its size, which matters because the system
  prompt asks for plain text on a low-resolution screen.
- Pascal cards have no fast FP16 path, so a 4-bit quant is the right call
  anyway. Expect roughly 25–40 tokens/sec.

**Alternatives**, switchable at runtime with `/model <name>`:

| Model | Size | When to use it |
|---|---|---|
| `llama3.1:8b` | ~4.9 GB | Also tool-capable; slightly chattier, a bit looser about strict output formats |
| `qwen2.5-coder:7b` | ~4.7 GB | If you mostly ask it about Lua and file contents |
| `qwen3:8b` | ~5.2 GB | Newer and stronger, but its thinking tokens add latency over the in-game network |
| `qwen2.5:14b-instruct` | ~9 GB | **Don't** — it does not fit in 8 GB and will crawl |

---

## Setup

### 1. On the machine running Ollama

```bash
ollama pull qwen2.5:7b-instruct
ollama serve
```

If Ollama and the Minecraft server are **different machines**, Ollama must
listen on more than loopback:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

### 2. Point ollama.lua at it

`OLLAMA_HOST` at the top of `ollama.lua` is the address **as seen from the
proxy computer's Internet Card** — that request is made by the Minecraft
server's JVM, so it is the server host's view of the network.

- Ollama on the same box as the MC server → `http://127.0.0.1:11434` (default)
- Ollama elsewhere on the LAN → `http://192.168.x.x:11434`

You can also change it live with `/host <url>` to test without editing files.

### 3. Raise the HTTP timeout (recommended)

`http.lua` ships with `local TIMEOUT = 30`. Local inference regularly runs
past that, especially on the first request of a session while the model is
still loading into VRAM. Change that one number:

```lua
local TIMEOUT = 180
```

`ollama.lua` mitigates this on its own — it preloads the model at startup and
caps replies at 600 tokens — but a long tool-heavy answer can still hit 30 s.
If you see `request timed out after 30s`, this is why, and the app will say so.

### 4. If OpenComputers refuses to connect

OpenComputers ships blocking **loopback and private addresses** — which is
exactly what a local Ollama is. In `opencomputers.cfg`, under `internet`, make
sure `enableHttp=true` and that your Ollama address is not caught by
`blacklist`. This is the most likely reason a local instance is unreachable.

---

## Troubleshooting

### "Could not reach Ollama — empty reply"

**Update `proxy.lua` on the proxy computer and restart it.** This repo's
version fixes the cause.

`internet.request()` in OpenComputers is **asynchronous** — it hands back a
handle before the connection exists. The original `proxy.lua` read from that
handle immediately, and OC returns `nil` from `read()` on a request that is not
ready yet, which the read loop could not tell apart from end-of-stream. The
result was a request that looked completely successful but carried an empty
body, with the status defaulting to `200 OK` because `handle.response()` also
had nothing to say yet.

Remote HTTPS hosts happened to win that race, which is why GitHub clones and
the browser worked. A local Ollama on `127.0.0.1` answers fast enough to lose
it every time.

The fix waits on `finishConnect()` before reading, and treats an empty-string
read as "nothing buffered yet" rather than as the end of the stream. The log
line now also reports the body size, so this failure is visible at the proxy:

```
[proxy]   -> 200 OK, 1523 bytes
[proxy]   -> 200 OK, 0 bytes  (status not reported by the card - assumed)
```

If it still fails after updating, in order:

1. `curl http://127.0.0.1:11434/api/tags` **on the machine hosting the
   Minecraft server** — not your desktop, if those are different boxes.
2. The `opencomputers.cfg` blacklist above.

`/diag` inside the app probes the connection and reports the status, body
length and first bytes of what actually came back, instead of trying to
interpret it.

### Long conversations failing

An OpenComputers modem drops any message over **8192 bytes**, and the reference
`http.lua` / `proxy.lua` send each request as a single modem message — so the
whole serialized request has to fit. In practice this binds long before
`NUM_CTX` does: the tool schemas and system prompt alone cost ~2.4 KB of every
request.

`ollama.lua` measures the encoded payload and trims the oldest messages until
it fits, so this is handled rather than fatal. What you will notice is the
model forgetting earlier turns sooner than 8192 tokens of context implies.

If you are running an `http.lua`/`proxy.lua` pair that **chunks** large
messages, set `MAX_REQUEST_BYTES = nil` and only `NUM_CTX` will limit you.

---

## Using it

```bash
ollama                       # full-screen chat UI
ollama "what lua files are in /home?"    # one-shot, prints and exits
ollama -u                    # unsafe mode: skip all confirmation prompts
ollama --model=llama3.1:8b   # override the model for this run
ollama --host=http://192.168.1.50:11434
```

### Keys

| Key | Does |
|---|---|
| `Enter` | Send |
| `Backspace` | Edit |
| `Delete` | Clear the input line (Minecraft eats `Esc`, same as `factory.lua`) |
| `↑` `↓` | Scroll one line |
| `PgUp` `PgDn` | Scroll one screen |
| `Home` / `End` | Jump to oldest / newest |

**The screen is touch enabled.** Tap the top or bottom third of the transcript
to scroll, and tap any footer button. Pasting into the terminal works too.

### Commands

| Command | Does |
|---|---|
| `/new` | Start a fresh conversation |
| `/model <name>` | Switch model (resets history) |
| `/models` | List models installed on the Ollama host |
| `/host <url>` | Point at a different Ollama instance |
| `/tools` | List the tools the model can call |
| `/diag` | Probe the connection and report exactly what came back |
| `/unsafe` | Toggle skipping permission prompts |
| `/save <path>` | Write the conversation to a file |
| `/help` | Command list |
| `/exit` | Quit |

---

## Tools the model can call

| Tool | Asks first? | Does |
|---|---|---|
| `read_file` | no | Read a file, optionally just a range of lines |
| `list_files` | no | List a directory |
| `search_files` | no | Find text across a directory tree, with file:line results |
| `write_file` | **yes** | Write or append, creating parent directories |
| `run_command` | **yes** | Run a shell command and return its output |

Read-only tools run unattended. Anything that can change the computer shows a
confirmation box you can answer by key (`Y` / `N`) or by tapping.

`search_files` exists because OpenOS has no `grep`, and "find where this is
defined" is the single most useful thing a coding assistant does.

### Unsafe mode

`-u` on the command line, or `/unsafe` in the chat, skips every confirmation.
The header turns red and says `UNSAFE` while it is on.

This lets the model write files and run shell commands on this computer with
no review. That is the point of it, and also the risk — a 7B model that
misreads a request can delete the wrong file just as easily as it can fix one.
Turn it on for a task, not for a session.

> Related: `proxy.lua`'s `ALLOWLIST` is empty by default, which means **any**
> computer on the network can route HTTP through it. Worth locking down before
> leaving the proxy running unattended.

---

## Notes on how it works

- **Non-streaming only.** Ollama's streaming responses are newline-delimited
  JSON; `proxy.lua` hands back the whole concatenated body, which is not a
  valid JSON document. `stream:false` is not optional here.
- **OpenAI-shaped tools, not Anthropic-shaped.** Ollama wants
  `{type:"function", function:{name, description, parameters}}` and returns
  `message.tool_calls`. That difference is why this is a separate file from
  `claude.lua` rather than a flag on it.
- **`num_ctx` is set explicitly.** Ollama's default context is small enough
  that a system prompt plus tool schemas plus one file read overflows it, and
  the symptom is the model silently forgetting the start of the conversation.
- **History is trimmed** oldest-first to stay inside that window, never
  dropping the system prompt and never leaving a tool result without the
  assistant turn that requested it (Ollama rejects that outright).
- **No `io.popen`.** It does not exist in OpenComputers, so `run_command`
  redirects through the shell to a temp file and reads that back. This also
  keeps command output from scribbling over the chat UI.

## Testing

`tests/harness.py` loads `ollama.lua` under stubbed OpenComputers APIs using a
real Lua interpreter (`pip install lupa`) and exercises the JSON encoder, the
request shape, word wrapping, history trimming, permission gating and the file
tools — 47 checks, no Minecraft required.

```bash
pip install lupa
python tests/harness.py
```
