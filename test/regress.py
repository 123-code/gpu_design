#!/usr/bin/env python3
"""Run make targets in order and check each prints `RESULT: PASS`.

    python3 test/regress.py sim-loadrun sim-mlp ...

Stops at the first target whose output has no PASS line (or has a FAIL line)
and exits non-zero. Used by `make regress` / `make regress-full`.
"""
import subprocess
import sys
import time

def main(targets):
    for t in targets:
        t0 = time.time()
        p = subprocess.run(["make", "-s", t], capture_output=True, text=True)
        out = p.stdout + p.stderr
        results = [l.strip() for l in out.splitlines() if "RESULT:" in l]
        ok = p.returncode == 0 and results and all("PASS" in r for r in results)
        dt = time.time() - t0
        print(f"{'ok  ' if ok else 'FAIL'} {t:<22} {dt:6.1f}s  {results[-1] if results else '(no RESULT line)'}")
        if not ok:
            print(out[-3000:])
            return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
