#!/usr/bin/env bash
# M3 borrow-checking gate for the final compiler: liveness-based loans,
# LOAN-01/02/03, reborrowing, disjoint fields and two-phase borrows.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HC="$ROOT/build/harmony"
DIR="$ROOT/tests/harmony-final/m3"
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

run_case nll 2
run_case shared 82
run_case disjoint-fields 42
run_case reborrow 12
run_case two-phase 40

reject err-shared-write LOAN-01
reject err-collection LOAN-01
reject err-two-mut LOAN-02
reject err-read-mut LOAN-03
reject err-mut-immutable MUT-03
reject err-method-alias LOAN-02

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
