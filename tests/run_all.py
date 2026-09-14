"""Run every suite. Exit non-zero if any of them fail.

    pip install lupa
    python tests/run_all.py          one line per suite
    python tests/run_all.py -v       full output
"""
import os.path
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

SUITES = [
    ("factory", "factory_harness.py", "auto-craft rules against a simulated ME network"),
    ("ollama", "harness.py", "chat client: JSON, prompt, tools, UI"),
    ("proxy", "proxy_harness.py", "proxy HTTP read path"),
    ("link", "link_harness.py", "http.lua <-> proxy.lua wire format"),
    ("tools", "tools_harness.py", "env, updater, doctor"),
]

verbose = "-v" in sys.argv or "--verbose" in sys.argv

failed = []
total = 0

for name, script, what in SUITES:
    proc = subprocess.run([sys.executable, os.path.join(HERE, script)],
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    passes = out.count("  pass  ")
    total += passes

    if verbose:
        print(out)

    if proc.returncode == 0:
        print("  ok    %-9s %3d checks   %s" % (name, passes, what))
    else:
        failed.append(name)
        print("  FAIL  %-9s %3d checks   %s" % (name, passes, what))
        if not verbose:
            # Just the failures, so the reason is visible without -v.
            for line in out.splitlines():
                if line.startswith("  FAIL") or "FAILURES" in line or "Error" in line:
                    print("          " + line.strip())

print("")
if failed:
    print("%d of %d suites failed: %s" % (len(failed), len(SUITES), ", ".join(failed)))
    sys.exit(1)
print("all %d suites passed, %d checks total" % (len(SUITES), total))
