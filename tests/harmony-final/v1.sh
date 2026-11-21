#!/usr/bin/env bash
# V1 features for the final compiler: structured unchecked reasons, guarded
# switch arms, Shared<T>/Weak<T>, threads with `fnptr`, and `else` clauses on
# fallible simple statements. The syntax forms are final-language only, so
# they are checked directly through `build/harmony`.
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
run_case shared 42
run_case shared-counts 42
run_case shared-expired 42
run_case thread-join 42
run_case thread-detached 42
run_case thread-multi 90
run_case else-forward 42
run_case else-maybe 42
run_case else-exits 42
run_case else-nested-exit 42

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

"$HC" check "$DIR/fnptr-not-fn.harmony" >"$TMP/fnptr.out" 2>&1
fnptr_rc=$?
if [ "$fnptr_rc" -ne 0 ] && grep -q 'TYPE-04' "$TMP/fnptr.out"; then
    ok "fnptr rejects a non-function argument"
else
    bad "fnptr rejects a non-function argument (exit $fnptr_rc)"
fi

"$HC" check "$DIR/thread-capability.harmony" >"$TMP/cap.out" 2>&1
cap_rc=$?
if [ "$cap_rc" -ne 0 ] && grep -q 'thread::ThreadArg' "$TMP/cap.out"; then
    ok "spawn requires the opaque Share capability"
else
    bad "spawn requires the opaque Share capability (exit $cap_rc)"
fi

"$HC" check "$DIR/else-flow-fallthrough.harmony" >"$TMP/flow1.out" 2>&1
flow1_rc=$?
if [ "$flow1_rc" -ne 0 ] && grep -q 'FLOW-01' "$TMP/flow1.out"; then
    ok "FLOW-01 rejects a falling-through else clause"
else
    bad "FLOW-01 rejects a falling-through else clause (exit $flow1_rc)"
fi

"$HC" check "$DIR/else-flow-error-type.harmony" >"$TMP/flow2.out" 2>&1
flow2_rc=$?
if [ "$flow2_rc" -ne 0 ] && grep -q 'FLOW-02' "$TMP/flow2.out"; then
    ok "FLOW-02 rejects mismatched error types"
else
    bad "FLOW-02 rejects mismatched error types (exit $flow2_rc)"
fi

"$HC" check "$DIR/else-flow-no-return.harmony" >"$TMP/flow3.out" 2>&1
flow3_rc=$?
if [ "$flow3_rc" -ne 0 ] && grep -q 'FLOW-03' "$TMP/flow3.out"; then
    ok "FLOW-03 rejects forwarding from a non-fallible return"
else
    bad "FLOW-03 rejects forwarding from a non-fallible return (exit $flow3_rc)"
fi

"$HC" check "$DIR/else-not-fallible.harmony" >"$TMP/notfallible.out" 2>&1
nf_rc=$?
if [ "$nf_rc" -ne 0 ] && grep -q 'needs a `Maybe` or `Outcome`' "$TMP/notfallible.out"; then
    ok "else rejects a non-Maybe/Outcome scrutinee"
else
    bad "else rejects a non-Maybe/Outcome scrutinee (exit $nf_rc)"
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
