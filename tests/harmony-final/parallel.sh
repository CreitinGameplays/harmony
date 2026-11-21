#!/usr/bin/env bash
# R7 multi-core compilation gate.
#
# The final compiler splits LLVM function lowering across forked workers by
# default. Forking must never change a byte of the emitted IR, and the worker
# count must never appear in the result. The compiler's own source is used as
# the large input because it has hundreds of functions and generic instances.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HC="$ROOT/build/harmony"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$HC" ] || [ ! -x "$HB" ]; then
    echo "error: build harmony-base and harmony first" >&2
    exit 1
fi

cd "$ROOT"

BIG="harmony/main.hr"
SMALL="tests/harmony/codegen/return-constant.harmony"
MODULE="tests/harmony/codegen/imports-main.harmony"

# Every worker count must produce the same bytes, including the auto default
# (no flag) and the explicit serial path.
for src in "$BIG" "$SMALL" "$MODULE"; do
    name="$(basename "$src")"
    if "$HC" emit-llvm --jobs=1 "$src" > "$TMP/serial" 2>"$TMP/err" \
       && "$HC" emit-llvm --jobs=2 "$src" > "$TMP/two" 2>>"$TMP/err" \
       && "$HC" emit-llvm --jobs=4 "$src" > "$TMP/four" 2>>"$TMP/err" \
       && "$HC" emit-llvm "$src" > "$TMP/auto" 2>>"$TMP/err" \
       && cmp -s "$TMP/serial" "$TMP/two" \
       && cmp -s "$TMP/serial" "$TMP/four" \
       && cmp -s "$TMP/serial" "$TMP/auto"; then
        ok "parallel IR is byte-identical ($name)"
    else
        bad "parallel IR is byte-identical ($name)"
        head -5 "$TMP/err" | sed 's/^/     /'
    fi
done

# The parallel path must still agree with harmony-base's byte-deterministic IR.
if "$HB" emit-llvm "$BIG" > "$TMP/base" 2>/dev/null \
   && "$HC" emit-llvm --jobs=4 "$BIG" > "$TMP/parallel" 2>/dev/null \
   && cmp -s "$TMP/base" "$TMP/parallel"; then
    ok "parallel IR matches harmony-base"
else
    bad "parallel IR matches harmony-base"
fi

# Building and running through workers still returns the program exit code.
if "$HC" build --jobs=2 "$SMALL" -o "$TMP/built" >/dev/null 2>&1 \
   && [ -x "$TMP/built" ]; then
    "$TMP/built"
    built_rc=$?
    if [ "$built_rc" -eq 42 ]; then
        ok "parallel build produces a working executable"
    else bad "parallel build produced exit $built_rc"; fi
else bad "parallel build produces a working executable"; fi
"$HC" run --jobs=2 "$SMALL" >/dev/null 2>&1
run_rc=$?
if [ "$run_rc" -eq 42 ]; then
    ok "parallel run returns the program exit code"
else bad "parallel run returns the program exit code (got $run_rc)"; fi

# Bad job counts are a usage error, never a silent fallback.
"$HC" emit-llvm --jobs=abc "$BIG" > "$TMP/bad.out" 2> "$TMP/bad.err"
bad_rc=$?
if [ "$bad_rc" -ne 0 ] && grep -q 'bad job count' "$TMP/bad.err"; then
    ok "rejects a bad job count"
else bad "rejects a bad job count (exit $bad_rc)"; fi

# Optional: prove the default really forks. strace is a measuring tool, not a
# build dependency, so this check is skipped when it is not installed.
if command -v strace >/dev/null 2>&1; then
    timeout 120 strace -f -e trace=fork,clone,vfork \
        "$HC" emit-llvm --jobs=4 "$BIG" >/dev/null 2>"$TMP/trace"
    forks=$(grep -c -E 'fork\(|clone\(|vfork\(' "$TMP/trace" || true)
    if [ "${forks:-0}" -ge 2 ]; then
        ok "default large compile forks multiple workers ($forks)"
    else
        bad "default large compile forks multiple workers (got $forks)"
    fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
