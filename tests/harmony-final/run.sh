#!/usr/bin/env bash
# harmony (the self-hosted compiler) tests — substrate and later phases.
#
# The rewrite under `harmony/` is built by harmony-base, but `library/core`
# and the phases in `roadmap/harmony` can be tested *before* the compiler
# exists: each case here imports the module under test, exercises it, and
# returns the `// EXPECT: <n>` value. Later phases add stage-level tests
# (dump-tokens, dump-ast, IR diffing) on top of the same harness.
#
# A case that must be *rejected* names its code in `// WANT: CODE`, like the
# error-handling suite. A case may also set `// EXPECT-TRAP: <code>`.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
CASES="$ROOT/tests/harmony-final"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
    local src="$1"
    local name
    name="$(basename "$src" .harmony)"
    local expect trap want
    expect="$(sed -n 's|^// EXPECT: *\([0-9]*\).*|\1|p' "$src" | head -1)"
    trap="$(sed -n 's|^// EXPECT-TRAP: *\([A-Z0-9-]*\).*|\1|p' "$src" | head -1)"
    want="$(sed -n 's|^// WANT: *||p' "$src" | head -1)"

    "$HB" check "$src" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    if [ "$rc" -ge 128 ]; then
        fail=$((fail + 1)); printf 'FAIL %s (compiler crashed, exit %s)\n' "$name" "$rc"; return
    fi
    if [ -n "$want" ]; then
        if [ "$rc" -eq 0 ]; then
            fail=$((fail + 1)); printf 'FAIL %s (accepted; expected rejection)\n' "$name"; return
        fi
        local missing=""
        local code
        for code in $want; do
            grep -q "$code" "$TMP/out" || missing="$missing $code"
        done
        if [ -n "$missing" ]; then
            fail=$((fail + 1)); printf 'FAIL %s (missing code(s):%s)\n' "$name" "$missing"; return
        fi
        pass=$((pass + 1)); printf 'ok   %s (rejected %s)\n' "$name" "$want"
        return
    fi

    if [ -z "$expect" ] && [ -z "$trap" ]; then
        # A case with no expectation only has to *check* cleanly.
        if [ "$rc" -eq 0 ]; then
            pass=$((pass + 1)); printf 'ok   %s (checks)\n' "$name"
        else
            fail=$((fail + 1)); printf 'FAIL %s (did not check)\n' "$name"
            sed -n '1,6p' "$TMP/out" | sed 's/^/     /'
        fi
        return
    fi

    "$HB" run "$src" >"$TMP/rout" 2>"$TMP/rerr"
    rc=$?
    if [ "$rc" -ge 128 ] && grep -q "killed by signal" "$TMP/rerr"; then
        fail=$((fail + 1)); printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"; return
    fi
    if [ -n "$trap" ]; then
        if [ "$rc" = "70" ] && grep -q "$trap" "$TMP/rerr"; then
            pass=$((pass + 1)); printf 'ok   %s (trap %s)\n' "$name" "$trap"
        else
            fail=$((fail + 1)); printf 'FAIL %s (wanted trap %s, exit %s)\n' "$name" "$trap" "$rc"
        fi
        return
    fi
    if [ "$rc" = "$expect" ]; then
        pass=$((pass + 1)); printf 'ok   %s (%s)\n' "$name" "$rc"
    else
        fail=$((fail + 1)); printf 'FAIL %s (want %s, got %s)\n' "$name" "$expect" "$rc"
        sed -n '1,6p' "$TMP/rerr" | sed 's/^/     /'
    fi
}

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (HARMONY=$HARMONY; run 'make all' first)" >&2
    exit 1
fi

for src in "$CASES"/*.harmony; do
    [ -e "$src" ] || continue
    run_case "$src"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
