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

# A large build must survive the parallel clang path: every chunk gets the
# sibling declarations it needs, and the linked binary must work. Rebuilding
# with that binary must stay byte-identical.
want="harmony $(cat VERSION)"
if "$HC" build harmony/main.hr -o "$TMP/self1" >/dev/null 2>"$TMP/self.err" \
   && [ "$("$TMP/self1" --version 2>/dev/null)" = "$want" ] \
   && "$TMP/self1" build harmony/main.hr -o "$TMP/self2" >/dev/null 2>>"$TMP/self.err" \
   && cmp -s "$TMP/self1" "$TMP/self2"; then
    ok "parallel clang self-build is byte-deterministic"
else
    bad "parallel clang self-build is byte-deterministic"
    head -10 "$TMP/self.err" | sed 's/^/     /'
fi

# `--backend=clang` stays available for debugging: it must still produce the
# same byte-identical IR text, and a clang-compiled program must still run.
if "$HC" emit-llvm --jobs=1 "$BIG" > "$TMP/big-serial" 2>/dev/null \
   && "$HC" emit-llvm --backend=clang "$BIG" > "$TMP/clang-ir" 2>/dev/null \
   && cmp -s "$TMP/clang-ir" "$TMP/big-serial"; then
    ok "clang backend keeps the same emit-llvm bytes"
else bad "clang backend keeps the same emit-llvm bytes"; fi
if "$HC" build --backend=clang --jobs=1 "$SMALL" -o "$TMP/clang-built" >/dev/null 2>&1 \
   && [ -x "$TMP/clang-built" ]; then
    "$TMP/clang-built"
    clang_rc=$?
    if [ "$clang_rc" -eq 42 ]; then ok "clang debug backend still works"
    else bad "clang debug backend returned $clang_rc"; fi
else bad "clang debug backend still works"; fi

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

if command -v strace >/dev/null 2>&1; then
    timeout 120 strace -f -e trace=execve \
        "$HC" build "$SMALL" -o "$TMP/native" >/dev/null 2>"$TMP/exec.trace"
    if grep -q 'execve("/usr/bin/clang"' "$TMP/exec.trace"; then
        bad "default build does not spawn clang"
    else
        ok "default build does not spawn clang"
    fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
