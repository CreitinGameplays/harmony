#!/usr/bin/env bash
# First v1 batch for the final compiler: structured unchecked reasons and
# guarded switch arms. These forms are final-language only; harmony-base does
# not parse them, so they are checked directly through `build/harmony`.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HC="$ROOT/build/harmony"
DIR="$ROOT/tests/harmony-final/v1"
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
        head -5 "$TMP/$name.err" | sed 's/^/     /'
    fi
}

run_case structured-reason 42
run_case structured-reason-fn 42
run_case switch-guard 42
run_case switch-guard-false 42
run_case guarded-exhaustive 42

"$HC" check "$DIR/guarded-refutable.harmony" >"$TMP/refutable.out" 2>&1
refutable_rc=$?
if [ "$refutable_rc" -ne 0 ] && grep -q 'CASE-01' "$TMP/refutable.out"; then
    ok "a refutable guarded arm needs a default"
else
    bad "a refutable guarded arm needs a default (exit $refutable_rc)"
fi

"$HC" check "$DIR/guard-not-bool.harmony" >"$TMP/guard.out" 2>&1
guard_rc=$?
if [ "$guard_rc" -ne 0 ] && grep -q 'TYPE-03' "$TMP/guard.out"; then
    ok "rejects a non-bool switch guard"
else
    bad "rejects a non-bool switch guard (exit $guard_rc)"
fi

"$HC" audit --format=json "$DIR/structured-reason.harmony" >"$TMP/audit.json" 2>/dev/null
if grep -q '"tag":"index_checked"' "$TMP/audit.json" \
   && grep -q '"reason":"i < len on line 5"' "$TMP/audit.json"; then
    ok "audit reports the structured reason tag"
else
    bad "audit reports the structured reason tag"
    head -3 "$TMP/audit.json" | sed 's/^/     /'
fi

# The plain form must still render exactly as before (no tag field).
"$HC" audit --format=json "$DIR/structured-reason-fn.harmony" >"$TMP/audit-fn.json" 2>/dev/null
if grep -q '"tag":"raw_op"' "$TMP/audit-fn.json" \
   && grep -q '"reason":"the caller owns p and v fits"' "$TMP/audit-fn.json"; then
    ok "audit handles mixed tagged and plain sites"
else
    bad "audit handles mixed tagged and plain sites"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
