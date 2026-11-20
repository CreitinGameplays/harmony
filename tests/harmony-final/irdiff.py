#!/usr/bin/env python3
"""Byte-for-byte LLVM IR differential gate (roadmap/harmony R6, gate 1).

The rewrite's emitter and harmony-base's emitter must produce the *same bytes*
for every accepted program in the corpus. The rewrite is compiled once into a
batch driver (lowering ~2,600 lines of Harmony for every case separately is
far too slow); the driver then prints each program's IR between markers.

    python3 tests/harmony-final/irdiff.py [corpus-directory]
"""
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typeharness

ROOT = typeharness.ROOT
HB = typeharness.HB
TEMPLATE = os.path.join(ROOT, "tests/harmony-final/irbatch.hr")
DRIVER = os.path.join(ROOT, "tests/harmony-final/irbatch_gen.hr")


def corpus(which):
    directory = os.path.join(ROOT, "tests/harmony", which)
    names, sources = [], []
    for fn in sorted(os.listdir(directory)):
        if not fn.endswith(".harmony"):
            continue
        src = open(os.path.join(directory, fn)).read()
        if 'import "' in src:
            continue        # multi-module programs need the loader (R7)
        names.append(fn)
        sources.append(src)
    return names, sources


def build_driver(sources):
    body = open(TEMPLATE).read()
    lits = ",\n        ".join('"%s"' % typeharness.hs(src) for src in sources)
    arr = "let sources: [&str; %d] = [\n        %s,\n    ];" % (len(sources), lits)
    body = re.sub(r"let sources: \[&str; \d+\] = \[.*?\];",
                  lambda _m: arr, body, count=1, flags=re.S)
    open(DRIVER, "w").write(body)
    work = tempfile.mkdtemp(prefix="harmony-irbatch-", dir="/tmp/opencode")
    out = os.path.join(work, "batch")
    b = subprocess.run([HB, "build", DRIVER, "-o", out],
                       capture_output=True, text=True)
    if b.returncode != 0:
        raise SystemExit("IR batch driver build failed:\n" + (b.stdout + b.stderr)[:4000])
    return out


def split_ir(output):
    result = {}
    pattern = re.compile(r"@@@CASE (\d+)\n@@@IR\n(.*?)@@@END \d+\n", re.S)
    for m in pattern.finditer(output):
        result[int(m.group(1))] = m.group(2).encode()
    return result


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "codegen"
    names, sources = corpus(which)
    if not names:
        print("no cases")
        return 1
    t0 = time.time()
    driver = build_driver(sources)
    t1 = time.time()
    rewrite = {}
    mismatches = 0
    for i, (name, src) in enumerate(zip(names, sources)):
        # One process per case keeps a runtime trap in one lowered program
        # from hiding every later case. The expensive part (compiling the
        # emitter) still happens only once.
        run = subprocess.run([driver, str(i)], capture_output=True, text=True)
        rewrite.update(split_ir(run.stdout))
        path = os.path.join(ROOT, "tests/harmony", which, name)
        oracle = subprocess.run([HB, "emit-llvm", path], capture_output=True)
        expected = oracle.stdout
        got = rewrite.get(i)
        if got != expected:
            mismatches += 1
            print("MISMATCH %s" % name)
            if got is None:
                print("  rewrite produced no IR")
                continue
            diff = difflib.unified_diff(
                expected.decode(errors="replace").splitlines(),
                got.decode(errors="replace").splitlines(),
                fromfile="harmony-base", tofile="harmony", lineterm="")
            for line in list(diff)[:40]:
                print("  " + line)
    try:
        os.remove(DRIVER)
    except OSError:
        pass
    shutil.rmtree(os.path.dirname(driver), ignore_errors=True)
    t2 = time.time()
    print("\nbuild %.2fs, diff %.2fs, %d cases, %d mismatches" %
          (t1 - t0, t2 - t1, len(names), mismatches))
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
