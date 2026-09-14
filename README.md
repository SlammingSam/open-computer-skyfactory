# open-computer-skyfactory

OpenComputers (MC 1.12.2) tooling for a SkyFactory world: an AE2 dashboard with
auto-crafting, a local-LLM chat client with tool access, and the networking
that lets a computer with only a Network Card reach the internet.

## Layout

```
bin/     programs you run          -> installed to /home/bin
lib/     shared modules            -> installed to /home/lib
diag/    one-off diagnostics       -> installed to /home/diag
docs/    documentation             (not installed by default)
tests/   test suites, run on a PC  (never installed)
reference/  unmodified originals, for comparison only
```

| Program | Runs on | What it does |
|---|---|---|
| `bin/factory.lua` | the AE2 computer | ME dashboard, auto-crafting rules, log |
| `bin/ollama.lua` | any client | chat with a local LLM, with tool access to that computer |
| `bin/proxy.lua` | the computer with the **Internet Card** | serves HTTP to everyone else over the modem |
| `bin/update.lua` | any computer | pulls changed files from this repo |
| `bin/nettest.lua` | the proxy computer | probes the Internet Card when something cannot connect |
| `lib/http.lua` | any client | HTTP over the modem, via the proxy |
| `lib/json.lua` | — | JSON encode/decode |
| `lib/env.lua` | — | reads `/home/.env` |

## Setup

Clone once, then let the updater keep things current:

```
git clone https://github.com/SlammingSam/open-computer-skyfactory /mnt/xxx
cp /mnt/xxx/bin/update.lua /home/bin/update.lua
cp /mnt/xxx/lib/*.lua /home/lib/
update
```

Then, on each machine, create `/home/.env` from [.env.example](.env.example)
and fill in what that machine needs.

### Keeping it current

```
update                     pull changed files, skip everything unchanged
update --list              show what would change, write nothing
update --install-startup   run the updater automatically at boot
```

`update` asks GitHub for the repo tree, which includes a blob SHA per file, and
compares those against `/home/.update_state`. **Files whose SHA has not changed
are never downloaded and never written** — their contents and timestamps are
left completely alone. A file missing locally is restored even if its SHA
matches, and a truncated download is not recorded, so the next run retries it.

`/home/.env` is never written by the updater.

## Configuration and secrets

Everything machine-specific lives in `/home/.env`, which the updater will not
touch — so settings survive every update. See [.env.example](.env.example) for
the full list.

```
PROXY_ADDRESS=e66d90a3-...      # optional; discovered automatically if absent
OLLAMA_HOST=http://127.0.0.1:11434
OLLAMA_MODEL=qwen2.5:7b-instruct
GITHUB_TOKEN=                    # optional, only raises the API rate limit
ANTHROPIC_API_KEY=
```

`.env` is gitignored. Do not commit a filled-in copy.

If `PROXY_ADDRESS` is absent, `lib/http.lua` broadcasts for the proxy, and
writes the answer back to `.env` so it only ever costs one discovery.

## Networking

A client needs only a Network Card. The proxy machine has the Internet Card and
makes the real requests:

```
client ──modem──► bin/proxy.lua ──Internet Card──► the internet
 (lib/http.lua)
```

Two things about this are not obvious and both have bitten this project:

- **Messages over 8192 bytes are dropped**, and a rack relays packets with a
  per-tick budget, so a burst loses its tail. Requests are tiny and always
  arrive; replies are not. Both sides chunk anything larger, which is why
  `http.lua` and `proxy.lua` must be updated together.
- **OpenComputers blacklists loopback and private addresses by default**, and
  the Internet Card does not surface the refusal — it looks like a successful
  empty response. To reach a service on the server host (such as Ollama), the
  loopback entries have to come out of `blacklist` in `opencomputers.cfg`. See
  [docs/OLLAMA.md](docs/OLLAMA.md).

`bin/nettest.lua`, run on the proxy computer, tells you which of these you are
looking at.

## Tests

There is no Lua on a typical dev machine, so the suites run under a real
interpreter via [lupa](https://pypi.org/project/lupa/), with the OpenComputers
APIs stubbed. No Minecraft required.

```bash
pip install lupa
python tests/harness.py         # ollama.lua: JSON, request shape, UI, tools
python tests/proxy_harness.py   # proxy.lua: the HTTP read path
python tests/link_harness.py    # http.lua <-> proxy.lua wire format
python tests/tools_harness.py   # env.lua and update.lua
```

These are not decorative. They have caught a corrupted JSON escape table,
scroll controls inverted in every direction, and a proxy regression that
silently dropped requests.
