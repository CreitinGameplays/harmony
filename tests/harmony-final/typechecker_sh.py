#!/usr/bin/env python3
"""Runs the rewrite checker against the inline snippets in tests/harmony/checker.sh.

The shell test writes each program to a file and expects a clean check or a
specific code. We extract those snippets and compare the rewrite's codes with
harmony-base's on the same source (one batched build for all of them).
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typeharness

ROOT = typeharness.ROOT
HB = typeharness.HB
TMP = tempfile.mkdtemp(prefix="hd-checker-", dir="/tmp/opencode")


def extract():
    src = open(os.path.join(ROOT, "tests/harmony/checker.sh")).read()
    out = []
    for m in re.finditer(r"^write '((?:[^'\\]|\\.)*)'\n(ok_case|reject_case) \"([^\"]*)\"",
                         src, re.M):
        body, kind, name = m.group(1), m.group(2), m.group(3)
        text = body.encode().decode("unicode_escape")
        out.append((name, text))
    return out


def hb_codes(src):
    f = os.path.join(TMP, "c.harmony")
    open(f, "w").write(src)
    r = subprocess.run([HB, "check", "--all", f], capture_output=True, text=True)
    return set(re.findall(r"\b([A-Z]+-\d+)\b", r.stdout + r.stderr))


def main():
    cases = extract()
    rw = dict(typeharness.run_cases(cases))
    fail = 0
    for name, src in cases:
        hb = hb_codes(src)
        got = rw.get(name, set())
        if hb != got:
            print("%-45s hb=%-24s rw=%s" % (name, sorted(hb), sorted(got)))
            fail += 1
    print("\nmatch %d mismatch %d" % (len(cases) - fail, fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
