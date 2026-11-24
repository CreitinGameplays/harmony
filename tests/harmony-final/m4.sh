#!/usr/bin/env bash
# M4 lifetime gate for the final compiler: elision, life(static), named lives,
# structs with lifetimes, and the LIFE-01..04 diagnostics.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
DIR="$ROOT/tests/harmony-final/m4"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$HC" ]; then
    echo "error: build harmony first" >&2
    exit 1
fi
cd "$ROOT"

run_case() {
    local name="$1" want="$2" rc
    "$HC" run "$DIR/$name.harmony" >"$TMP/$name.out" 2>"$TMP/$name.err"
    rc=$?
    if [ "$rc" -eq "$want" ]; then
        ok "$name (exit $rc)"
    else
        bad "$name (want $want, got $rc)"
        head -6 "$TMP/$name.err" | sed 's/^/     /'
    fi
}

reject() {
    local name="$1" code="$2" rc
    "$HC" check "$DIR/$name.harmony" >"$TMP/$name.out" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q "$code" "$TMP/$name.out"; then
        ok "$name ($code)"
    else
        bad "$name (want $code, exit $rc)"
        head -6 "$TMP/$name.out" | sed 's/^/     /'
    fi
}

run_case elision 3
run_case longest 3
run_case two-lives 3
run_case static 2
run_case struct-life 6

reject err-elision LIFE-03
reject err-elision-three LIFE-03
reject err-local-ref LIFE-03
reject err-local-annotated LIFE-01
reject err-local-int LIFE-01
reject err-local-field LIFE-01
reject err-outlive-int LIFE-02
reject err-outlive-ref LIFE-02
reject err-outlive-widened LIFE-02
reject err-contradict LIFE-04
reject err-contradict-int LIFE-04
reject err-contradict-method LIFE-04

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
