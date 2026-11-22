#!/usr/bin/env python3
"""Shared batched differential harness for the R5 type checker.

Compiling the rewrite's core modules takes ~5s, so compiling the checker ONCE
and feeding every program through a generated batch driver keeps the whole
corpus at one build plus one run. Each case becomes a string literal in the
generated driver; the driver prints `CASE i` / `DIAG <code>` / `END i`, and we
split the output on those markers.

`run_cases(cases)` takes `[(name, source), ...]` and returns
`[(name, codes_set), ...]`.
"""
import os
import re
import subprocess
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HB = os.path.join(ROOT, "build", "harmony-base")
TMP = tempfile.mkdtemp(prefix="hd-batch-")
BATCH = os.path.join(ROOT, "tests/harmony-final/typebatch.hr")


def hs(s):
    """Escape a program for embedding as a Harmony string literal."""
    o = []
    for c in s:
        if c == "\\": o.append("\\\\")
        elif c == '"': o.append('\\"')
        elif c == "\n": o.append("\\n")
        elif c == "\r": o.append("\\r")
        elif c == "\t": o.append("\\t")
        elif ord(c) < 32 or ord(c) >= 127: o.append("\\u{%x}" % ord(c))
        else: o.append(c)
    return "".join(o)


def run_cases(cases):
    """Compiles the batch driver once and runs every case in one process."""
    if not cases:
        return []
    body = open(BATCH).read()
    # Rewrite the `let sources: [&str; N] = [...]; while (i < N)` block with the
    # real corpus. (A lambda replacement: re.sub would otherwise treat the
    # `\n` escapes in the literals as real newlines and choke on `\u{..}`.)
    lits = ",\n        ".join('"%s"' % hs(src) for _, src in cases)
    arr = "let sources: [&str; %d] = [\n        %s,\n    ];" % (len(cases), lits)
    body = re.sub(r"let sources: \[&str; \d+\] = \[.*?\];",
                  lambda _m: arr, body, count=1, flags=re.S)
    body = re.sub(r"while \(i < \d+\) \{", "while (i < %d) {" % len(cases),
                  body, count=1)
    # The driver must live beside the template so its relative imports
    # (`../../library/core/...`) resolve; it is removed after the run.
    drv = os.path.join(ROOT, "tests/harmony-final/typebatch_gen.hr")
    open(drv, "w").write(body)
    # Build once. Build the binary into the temp dir (outside the repo).
    out = os.path.join(TMP, "batchbin")
    b = subprocess.run([HB, "build", drv, "-o", out], capture_output=True, text=True)
    if b.returncode != 0:
        raise SystemExit("batch driver build failed:\n" + (b.stdout + b.stderr)[:4000])
    try:
        r = subprocess.run([out], capture_output=True, text=True)
    finally:
        if os.path.exists(drv):
            os.remove(drv)
    # Split on CASE/END markers.
    results = {}
    cur = None
    for line in r.stdout.splitlines():
        m = re.match(r"CASE (\d+)", line)
        if m:
            cur = int(m.group(1))
            results[cur] = set()
            continue
        m = re.match(r"DIAG (\w+-\d+)", line)
        if m and cur is not None:
            results[cur].add(m.group(1))
            continue
        if re.match(r"END (\d+)", line):
            cur = None
    return [(name, results.get(i, set())) for i, (name, _) in enumerate(cases)]
