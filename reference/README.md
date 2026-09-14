# reference/

Unmodified copies of the three files this in-game toolchain is built on, kept
so changes elsewhere can be compared against the originals.

**Do not deploy anything from this folder.** These are snapshots, not the
working versions.

| File | Status |
|---|---|
| `proxy.lua` | **Superseded.** Contains the async-connection bug described below. Use `/proxy.lua` at the repo root instead. |
| `http.lua` | Original. The live copy carries your own `PROXY_ADDRESS`, so do not overwrite it from here. |
| `claude.lua` | Original. Starting point for `ollama.lua`; its `run_command` uses `io.popen`, which does not exist in OpenComputers. |

## The proxy bug, for reference

`internet.request()` is asynchronous — it returns a handle before the
connection has been established. `reference/proxy.lua` reads that handle
immediately, and OpenComputers returns `nil` from `read()` on a request that is
not ready yet, which its read loop cannot distinguish from end-of-stream.

The symptom is a request that looks entirely successful but carries an empty
body, reported as `200 OK` because `handle.response()` has nothing to say
either and the code falls back to a hardcoded default. Remote HTTPS hosts have
enough handshake latency to win that race; a loopback address loses it every
time, which is why GitHub clones worked while a local Ollama never did.

The root `proxy.lua` waits on `finishConnect()` before reading, treats an
empty-string read as "nothing buffered yet" rather than as the end, logs the
body size so an empty body is visible at the proxy, and refuses to send a reply
over the 8192-byte modem limit instead of letting it vanish silently.

`tests/proxy_harness.py` covers all of that against a simulated Internet Card.
