#!/usr/bin/env bash
# c2x-seed regression tests.
#
# Each case is a self-contained .c2 program whose `main` returns a sentinel
# exit code (documented in an `// EXPECT: <n>` line). The runner compiles each
# case with build/c2x-seed, runs it, and checks the exit code. Cases marked
# `// COMPILE-ONLY` only need to build (they exercise codegen paths whose
# runtime behaviour is checked elsewhere).
#
# This corpus guards the c2x-seed bugs fixed while bringing up harmony-base:
#   - binary-expression indices on struct-field pointers (s.p[i + 2])
#   - local/global struct arrays (struct Point pts[3])
#   - address-of a struct-array field through a pointer (&r->spans[0])
#   - nested struct member chains (b.a.x, c.b.a.x)
#   - index-rooted member chains (o[0].inner.a)
#   - struct field copies and global struct arrays of struct-with-array fields
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED="$ROOT/build/c2x-seed"
CASES="$ROOT/tests/c2x-seed/cases"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
    local src="$1"
    local name
    name="$(basename "$src" .c2)"
    local expect
    expect="$(sed -n 's|^// EXPECT: *\([0-9]*\).*|\1|p' "$src" | head -1)"
    local compile_only=0
    grep -q '^// COMPILE-ONLY' "$src" && compile_only=1

    local out="$TMP/$name"
    if ! "$SEED" -r -o "$out" "$src" >"$TMP/log" 2>&1; then
        fail=$((fail + 1))
        printf 'FAIL %s (compile error)\n' "$name"
        sed 's/^/     /' "$TMP/log" | head -5
        return
    fi
    if [ "$compile_only" = "1" ]; then
        pass=$((pass + 1))
        printf 'ok   %s (compiled)\n' "$name"
        return
    fi
    "$out" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok   %s (exit %s)\n' "$name" "$got"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$expect" "$got"
    fi
}

if [ ! -x "$SEED" ]; then
    echo "error: $SEED not built (run 'bash build.sh' first)" >&2
    exit 1
fi

shopt -s nullglob
for src in "$CASES"/*.c2; do
    run_case "$src"
done

# Negative cases: each `faults/NAME.c2` must FAIL to compile with the expected
# error text (a `// WANT: <substring>` line). Guards error paths that used to
# crash the compiler.
run_fault_case() {
    local src="$1"
    local name
    name="$(basename "$src" .c2)"
    local want
    want="$(sed -n 's|^// WANT: *||p' "$src" | head -1)"

    if "$SEED" -r -o "$TMP/fault_$name" "$src" >"$TMP/flog" 2>&1; then
        fail=$((fail + 1))
        printf 'FAIL %s (compiled, expected a fault)\n' "$name"
        return
    fi
    if grep -q "$want" "$TMP/flog"; then
        pass=$((pass + 1))
        printf 'ok   %s (rejected)\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (wrong error, wanted "%s")\n' "$name" "$want"
        sed 's/^/     /' "$TMP/flog" | grep -v 'unknown warning' | head -3
    fi
}

shopt -s nullglob
for src in "$CASES"/faults/*.c2; do
    run_fault_case "$src"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
