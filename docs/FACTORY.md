# factory.lua — AE2 dashboard and auto-crafting

A live view of the ME network — stock, power, CPUs, running jobs — plus rules
that keep quantities where you want them without you watching.

Runs on the computer with the ME Interface or ME Controller adapter. Touch
enabled: every control responds to a tap as well as a key.

## The two kinds of rule

**Below** — keep something topped up.

> Iron Ingot, below 100, craft 64

When stock drops under the threshold, request that many. The usual case.

**Above** — convert a surplus into something else.

> Nether Quartz, above 35,000 → Block of Quartz, keep 5,000, ratio 4:1

This is the one worth understanding, because "above" does not mean "craft more
of it". It means *the watched item is piling up; turn the excess into something
denser*. The rule watches quartz, and crafts **blocks**. Quantity is
`(stock - keep) / ratio`, so at 40,000 quartz it orders `(40000 - 5000) / 4` =
8,750 blocks and leaves 5,000 loose quartz behind.

## Batch caps

A single AE2 crafting CPU can only plan so much. Ask for 97,124 of something
and AE2 simply cancels the job — which is how this feature was discovered.

- **`M` — all batch.** The ceiling for every rule without one of its own.
- **`B` — rule batch.** A cap for the selected rule alone. Blank or `0` clears
  it and the rule goes back to the global number.

Per-rule caps matter once the rules differ in cost. Quartz at 4:1 and Steel at
9:1 want very different batch sizes, and one global number has to be tuned for
whichever is most expensive — throttling everything cheaper.

An overridden cap shows in the rule's ACTION column as `max 250`.

## CPU sharing and order

Rules dispatch **in list order**, one job each, until the free CPUs run out.
That makes order meaningful: a rule near the top can take the last free CPU on
every pass and starve everything below it. **Shift+J** and **Shift+K** move the
selected rule down and up (lowercase `j`/`k` still move the cursor).

- **`V` — reserve.** CPUs held back from auto-crafting, so a manual craft
  always has somewhere to run instead of queuing behind a long conversion.
  Default 1.
- **One live job per rule.** A second job on the same recipe draws from the
  same ingredient pool, so it adds no throughput — it stalls until the first
  releases those inputs, which looks exactly like a hung CPU. Parallelism comes
  from *different* rules, whose ingredient chains are independent.

## When things do not fire

- **A failed ME read fires nothing.** When `getItemsInNetwork` fails, every
  count reads 0, which every below rule would treat as "empty, craft now". The
  evaluation loop refuses to act on a failed read at all.
- **Low power stops everything.** `P` sets a floor as a percentage of stored
  power; below it, no new job starts. Crafting is what drains the network, so
  the useful moment to stop is before starting more of it. Off by default —
  set it to something like 20 if you leave the base unattended.
- **A cancelled job pauses its rule** for two minutes. AE2 cancels what it
  cannot fulfil — a batch too large, or an ingredient it can neither find nor
  craft — and without the pause a doomed rule would reclaim every free CPU on
  every pass. The Log tab records it.
- **Rules are keyed by item *and* direction**, so the same item can have a
  below rule and an above rule without them colliding.

## Settings and the log

Settings live in `/home/.factory_settings.cfg`, written to a temp file that is
read back before it replaces the live one, with the previous copy kept as
`.bak` — losing power mid-write cannot leave you with defaults.

What is read back is also validated. A hand-edited file with a string where a
number belongs is coerced; a rule that is not a rule at all is dropped, and the
rest still run. A bad save cannot stop the dashboard starting.

`Tab` switches to the **Log**, which records every dispatch, completion,
cancellation and pause. `/` searches it.

A pause also **beeps** — the dashboard runs unattended, and a pause visible
only on screen is one nobody learns about until they walk past it. Set
`beep = false` in the settings file to silence it.

## Keys

| Key | Does |
|---|---|
| `Tab` | Switch between the rule list and the log |
| `A` | Add a rule |
| `Enter` | Edit the selected rule |
| `D` | Delete it |
| `Space` | Toggle one rule on or off |
| `E` | Master switch for all auto-crafting |
| `B` | Batch cap for the selected rule |
| `M` `V` `I` `P` | Global batch, reserved CPUs, check interval, power floor |
| `Shift+J` / `Shift+K` | Move the selected rule down / up |
| `O` | Back to the dashboard |
| `Delete` | Cancel or clear — Minecraft swallows `Esc` |

## Tests

`tests/factory_harness.py` drives the rule engine against a simulated ME
network — stock levels, CPU counts, cancelled jobs, damaged settings — without
Minecraft. It covers the quartz conversion above, the batch caps, the CPU
budget, and every guard listed here.
