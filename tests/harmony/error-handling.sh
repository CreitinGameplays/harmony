#!/usr/bin/env bash
# harmony-base error-handling tests (the project's "purposely bad code" suite).
#
# Every program under tests/harmony/error-handling/ is deliberately wrong,
# simple or complex. Each is expected to be *rejected* by the type checker
# with the diagnostic code named in its `// WANT: CODE` header line, and the
# compiler must never crash on any of them. A case may name several codes
# (`// WANT: TYPE-01 NAME-01`) when it exercises more than one check; all
# named codes must appear.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
CASES="$ROOT/tests/harmony/error-handling"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ "$(basename "$HB")" = "harmony-base" ]; then V1_LANE=0; else V1_LANE=1; fi

run_case() {
    local src="$1"
    local name
    name="$(basename "$src" .harmony)"
    local want
    want="$(sed -n 's|^// WANT: *||p' "$src" | head -1)"

    # v1 lifts its 5-stop display cap with --all; the legacy compiler already
    # prints every stop by default.
    if [ "$V1_LANE" -eq 1 ]; then
        "$HB" check --all "$src" >"$TMP/out" 2>&1
    else
        "$HB" check "$src" >"$TMP/out" 2>&1
    fi
    local rc=$?
    if [ "$rc" -ge 128 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (accepted; expected rejection)\n' "$name"
        return
    fi
    local missing=""
    local code
    for code in $want; do
        if ! grep -q "$code" "$TMP/out"; then
            missing="$missing $code"
        fi
    done
    if [ -z "$missing" ]; then
        pass=$((pass + 1))
        printf 'ok   %s (rejected with %s)\n' "$name" "$want"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (missing code(s):%s)\n' "$name" "$missing"
        sed 's/^/     /' "$TMP/out" | head -6
    fi
}

shopt -s nullglob
for src in "$CASES"/*.harmony; do
    run_case "$src"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
