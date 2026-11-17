#!/usr/bin/env bash
# harmony-base coverage regression (2026-11).
#
# The fuzzer's grammar sampler is the engine that reaches the most compiler
# code (measured with callgrind: 316 of the reachable functions, versus 227
# for the previous sampler and 60 for token mutation). That is a *property of
# the sampler*, not of the compiler — so a later change to the sampler could
# quietly collapse the coverage without any test failing.
#
# This test measures it directly: it generates a fixed set of programs and
# counts the distinct compiler functions they reach, then asserts that the
# count stays at or above the recorded baseline. A drop means the sampler
# stopped exercising something, and the fuzzing campaign has silently become
# weaker.
#
# Requires valgrind (callgrind). Skipped when it is absent.
#
# The baseline is a floor, not an exact number: callgrind's function
# attribution depends on the binary's layout, which changes with every
# rebuild. The floor is set ~10% below the measured value so ordinary churn
# does not trip it, while a real collapse (the sampler reaching 60 functions
# instead of 316) does.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The floor: measured 316 distinct compiler functions for 25 generated
# programs. A 10% margin keeps routine rebuild churn from tripping it.
BASELINE=280
NSAMPLES=25

if ! command -v valgrind >/dev/null 2>&1; then
    echo "skip coverage-regression (valgrind not installed)"
    exit 0
fi
if [ ! -x "$HB" ]; then
    echo "error: $HB not built (run 'make harmony-base' first)" >&2
    exit 1
fi

python3 - "$ROOT" "$TMP" "$NSAMPLES" <<'PY' > "$TMP/syms.txt"
import bisect, os, subprocess, sys
root, tmp, nsamples = sys.argv[1], sys.argv[2], int(sys.argv[3])
hb = os.path.join(root, "build", "harmony-base")
sys.path.insert(0, os.path.join(root, "tests", "fuzz2"))
import fuzz

# Address -> symbol, from the binary's own symbol table.
syms = []
for line in subprocess.run(["nm", "-n", hb], capture_output=True,
                           text=True).stdout.splitlines():
    p = line.split()
    if len(p) >= 3 and p[1] in "TtWw":
        try:
            syms.append((int(p[0], 16), p[2]))
        except ValueError:
            pass
addrs = [a for a, _ in syms]

def sym_of(a):
    i = bisect.bisect_right(addrs, a) - 1
    return syms[i][1] if i >= 0 else "?"

def covered(path, sub):
    out = os.path.join(tmp, "cg.out")
    if os.path.exists(out):
        os.unlink(out)
    subprocess.run(["valgrind", "--tool=callgrind",
                    "--callgrind-out-file=" + out, hb, sub, path],
                   capture_output=True)
    s = set()
    try:
        for line in open(out, errors="replace"):
            if line.startswith("fn="):
                m = line.split("0x")
                if len(m) > 1:
                    try:
                        s.add(sym_of(int(m[1].split()[0], 16)))
                    except ValueError:
                        pass
    except OSError:
        pass
    return s

reached = set()
n_ok = 0
for i in range(nsamples):
    import random
    rng = random.Random(2000 + i)
    g = fuzz.Gen(rng)
    g.budget = rng.randint(5, 60)
    p = os.path.join(tmp, "gen%d.harmony" % i)
    with open(p, "w") as f:
        f.write(g.program())
    # The fuzzer runs `check` on every program and `emit-llvm` on the ones
    # that pass, so the measurement follows the same path.
    reached |= covered(p, "check")
    if subprocess.run([hb, "check", p], capture_output=True).returncode == 0:
        n_ok += 1
        reached |= covered(p, "emit-llvm")

print("REACHED %d" % len(reached))
print("CLEAN %d" % n_ok)
for name in sorted(reached):
    print("FN %s" % name)
PY

reached="$(grep '^REACHED ' "$TMP/syms.txt" | awk '{print $2}')"
clean="$(grep '^CLEAN ' "$TMP/syms.txt" | awk '{print $2}')"

if [ -z "$reached" ]; then
    echo "FAIL coverage-regression (measurement produced no result)"
    exit 1
fi

echo "coverage: $reached distinct compiler functions ($clean/$NSAMPLES programs check-clean)"

if [ "$reached" -lt "$BASELINE" ]; then
    echo "FAIL coverage-regression ($reached < $BASELINE: the fuzzer's grammar"
    echo "     sampler stopped reaching compiler code — campaigns are now"
    echo "     weaker without any test failing)"
    exit 1
fi

echo "ok   coverage-regression ($reached >= $BASELINE)"
