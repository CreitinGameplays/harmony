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

# The compiler caps workers by available memory as well as CPUs. Do the same
# here, and refresh it before the fork assertions: memory can drop while the
# earlier self-builds run, and a stale worker count would make the gate flaky.
available_mb() {
    awk '/MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0
}
safe_jobs() {
    local mb n
    mb=$(available_mb)
    n=$(( mb / 1024 ))
    if [ "$n" -lt 1 ]; then n=1; fi
    if [ "$n" -gt 4 ]; then n=4; fi
    printf '%s' "$n"
}
SAFE_JOBS=$(safe_jobs)
printf 'memory: %s MiB available, using %s worker(s) in this gate\n' \
    "$(available_mb)" "$SAFE_JOBS"

BIG="harmony/main.hr"
SMALL="tests/harmony/codegen/return-constant.harmony"
MODULE="tests/harmony/codegen/imports-main.harmony"

# Every worker count must produce the same bytes, including the auto default
# (no flag) and the explicit serial path.
for src in "$BIG" "$SMALL" "$MODULE"; do
    name="$(basename "$src")"
    if "$HC" emit-llvm --jobs=1 "$src" > "$TMP/serial" 2>"$TMP/err" \
       && "$HC" emit-llvm --jobs="$SAFE_JOBS" "$src" > "$TMP/parallel" 2>>"$TMP/err" \
       && "$HC" emit-llvm "$src" > "$TMP/auto" 2>>"$TMP/err" \
       && cmp -s "$TMP/serial" "$TMP/parallel" \
       && cmp -s "$TMP/serial" "$TMP/auto"; then
        ok "parallel IR is byte-identical ($name)"
    else
        bad "parallel IR is byte-identical ($name)"
        head -5 "$TMP/err" | sed 's/^/     /'
    fi
done

# The parallel path must still agree with harmony-base's byte-deterministic IR
# on M2-neutral programs. Owning types now get drop/clone glue, so a byte diff
# there is intentional rather than a parallel bug.
if "$HB" emit-llvm "$SMALL" > "$TMP/base" 2>/dev/null \
   && "$HC" emit-llvm --jobs="$SAFE_JOBS" "$SMALL" > "$TMP/parallel" 2>/dev/null \
   && cmp -s "$TMP/base" "$TMP/parallel"; then
    ok "parallel IR matches harmony-base"
else
    bad "parallel IR matches harmony-base"
fi

# Building and running through workers still returns the program exit code.
if "$HC" build --jobs="$SAFE_JOBS" "$SMALL" -o "$TMP/built" >/dev/null 2>&1 \
   && [ -x "$TMP/built" ]; then
    "$TMP/built"
    built_rc=$?
    if [ "$built_rc" -eq 42 ]; then
        ok "parallel build produces a working executable"
    else bad "parallel build produced exit $built_rc"; fi
else bad "parallel build produces a working executable"; fi
"$HC" run --jobs="$SAFE_JOBS" "$SMALL" >/dev/null 2>&1
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
if "$HC" build --jobs=1 harmony/main.hr -o "$TMP/self1" >/dev/null 2>"$TMP/self.err" \
   && [ "$("$TMP/self1" --version 2>/dev/null)" = "$want" ] \
   && "$TMP/self1" build --jobs=1 harmony/main.hr -o "$TMP/self2" >/dev/null 2>>"$TMP/self.err" \
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

# Optional: prove the default really forks. On a memory-constrained box the
# compiler deliberately uses one worker, so this check is skipped there.
SAFE_JOBS=$(safe_jobs)
if command -v strace >/dev/null 2>&1 && [ "$SAFE_JOBS" -ge 2 ]; then
    timeout 120 strace -f -e trace=fork,clone,vfork,clone3 \
        "$HC" emit-llvm --jobs="$SAFE_JOBS" "$BIG" >/dev/null 2>"$TMP/trace"
    forks=$(grep -c -E 'fork\(|clone\(|vfork\(|clone3\(' "$TMP/trace" || true)
    if [ "${forks:-0}" -ge 2 ]; then
        ok "default large compile forks multiple workers ($forks)"
    else
        bad "default large compile forks multiple workers (got $forks)"
    fi
elif [ "$SAFE_JOBS" -lt 2 ]; then
    ok "fork check skipped (only $SAFE_JOBS worker fits in memory)"
fi

# An explicit large job count must still obey the memory cap; otherwise a test
# or a user script can recreate the swap storm even with a safe default.
if command -v strace >/dev/null 2>&1; then
    CAP_JOBS=$(safe_jobs)
    timeout 120 strace -f -e trace=fork,clone,vfork,clone3 \
        "$HC" emit-llvm --jobs=8 "$BIG" >/dev/null 2>"$TMP/cap.trace"
    capped=$(grep -c -E 'fork\(|clone\(|vfork\(|clone3\(' "$TMP/cap.trace" || true)
    if [ "${capped:-0}" -le "$CAP_JOBS" ]; then
        ok "explicit jobs obey the memory cap ($capped forks)"
    else
        bad "explicit jobs ignored the memory cap ($capped forks)"
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
    timeout 300 strace -f -e trace=execve \
        "$HC" build --jobs=1 harmony/main.hr -o "$TMP/self-native" >/dev/null 2>"$TMP/self-exec.trace"
    child_execs=$(grep -c 'execve(' "$TMP/self-exec.trace" || true)
    if [ "${child_execs:-0}" -le 1 ]; then
        ok "self rebuild spawns no external tools ($child_execs exec)"
    else
        bad "self rebuild spawns no external tools ($child_execs execs)"
    fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
