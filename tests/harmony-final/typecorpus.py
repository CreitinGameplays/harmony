#!/usr/bin/env python3
"""Differential check of the rewrite checker against harmony-base on a corpus
directory of `.harmony` files (single-file cases; imports are skipped)."""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typeharness

ROOT = typeharness.ROOT
HB = typeharness.HB
TMP = tempfile.mkdtemp(prefix="hd-corpus-", dir="/tmp/opencode")


def hb_codes(src):
    f = os.path.join(TMP, "c.harmony")
    open(f, "w").write(src)
    r = subprocess.run([HB, "check", "--all", f], capture_output=True, text=True)
    return set(re.findall(r"\b([A-Z]+-\d+)\b", r.stdout + r.stderr))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "error-handling"
    d = os.path.join(ROOT, "tests/harmony", which)
    names, sources = [], []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".harmony"):
            continue
        src = open(os.path.join(d, fn)).read()
        if 'import "' in src:
            continue   # multi-module: needs the loader (tested elsewhere)
        names.append(fn)
        sources.append(src)
    rw = dict(typeharness.run_cases(list(zip(names, sources))))
    fail = 0
    for fn, src in zip(names, sources):
        hb = hb_codes(src)
        got = rw.get(fn, set())
        if hb != got:
            print("%-40s hb=%-30s rw=%s" % (fn, sorted(hb), sorted(got)))
            fail += 1
    print("\nmatch %d mismatch %d" % (len(names) - fail, fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
