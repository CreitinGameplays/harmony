#!/usr/bin/env bash
# M6 gate for the final compiler: the seven-powers unchecked gate, blast-radius
# warning, --deny-unchecked, --strict, audit, and explain lessons.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HC="$ROOT/build/harmony"
DIR="$ROOT/tests/harmony-final/m6"
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

# Accepted: raw write, extern call and an unchecked fn call, each with a short
# promise. The program returns 10 + 7 + 3 = 20.
if "$HC" run --jobs=1 "$DIR/accept.harmony" >"$TMP/accept.out" 2>"$TMP/accept.err"; then
    rc=0
else
    rc=$?
fi
if [ "$rc" -eq 20 ]; then
    ok "accept runs with the seven powers (exit 20)"
else
    bad "accept runs with the seven powers (got $rc)"
    head -6 "$TMP/accept.err" | sed 's/^/     /'
fi

reject() {
    local name="$1" code="$2" flags="${3:-}" rc
    # shellcheck disable=SC2086
    "$HC" $flags check "$DIR/$name.harmony" >"$TMP/$name.out" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q "$code" "$TMP/$name.out"; then
        ok "$name ($code)"
    else
        bad "$name (want $code, exit $rc)"
        head -6 "$TMP/$name.out" | sed 's/^/     /'
    fi
}

reject err-raw-deref UNCK-01
reject err-raw-index UNCK-01
reject err-raw-write UNCK-01
reject err-extern UNCK-01
reject err-unck-fn UNCK-04
reject err-weak-block UNCK-02
reject err-weak-contract UNCK-02

# UNCK-03 is a warning: it prints but does not stop unless --strict is given.
"$HC" check "$DIR/warn-blast-radius.harmony" >"$TMP/warn.out" 2>&1
warn_rc=$?
if [ "$warn_rc" -eq 0 ] && grep -q 'UNCK-03' "$TMP/warn.out"; then
    ok "blast radius warns without stopping"
else
    bad "blast radius warns without stopping (exit $warn_rc)"
    head -6 "$TMP/warn.out" | sed 's/^/     /'
fi
"$HC" --strict check "$DIR/warn-blast-radius.harmony" >"$TMP/strict.out" 2>&1
strict_rc=$?
if [ "$strict_rc" -ne 0 ] && grep -q 'UNCK-03' "$TMP/strict.out"; then
    ok "--strict turns the warning into a stop"
else
    bad "--strict turns the warning into a stop (exit $strict_rc)"
fi

# --deny-unchecked is a final-compiler flag (UNCK-05).
"$HC" --deny-unchecked check "$DIR/accept.harmony" >"$TMP/deny.out" 2>&1
deny_rc=$?
if [ "$deny_rc" -ne 0 ] && grep -q 'UNCK-05' "$TMP/deny.out"; then
    ok "--deny-unchecked rejects every site"
else
    bad "--deny-unchecked rejects every site (exit $deny_rc)"
    head -6 "$TMP/deny.out" | sed 's/^/     /'
fi

# Audit is read-only and byte-stable in both pretty and JSON forms.
if "$HC" audit "$DIR/audit-sites.harmony" >"$TMP/audit.out" 2>&1 \
    && grep -q 'sites' "$TMP/audit.out" \
    && grep -q 'index_checked' "$TMP/audit.out"; then
    ok "audit lists tagged sites"
else
    bad "audit lists tagged sites"
    head -6 "$TMP/audit.out" | sed 's/^/     /'
fi
if "$HC" audit --format=json "$DIR/audit-sites.harmony" >"$TMP/audit.json" 2>&1 \
    && grep -q '"tag":"index_checked"' "$TMP/audit.json" \
    && grep -q '"total":2' "$TMP/audit.json"; then
    ok "audit --format=json reports tags and totals"
else
    bad "audit --format=json reports tags and totals"
    head -4 "$TMP/audit.json" | sed 's/^/     /'
fi

for code in UNCK-01 UNCK-02 UNCK-03 UNCK-04 UNCK-05; do
    if "$HC" explain "$code" >"$TMP/explain.out" 2>&1 \
        && grep -q "^$code" "$TMP/explain.out"; then
        ok "explain $code"
    else
        bad "explain $code"
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
