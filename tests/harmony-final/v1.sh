#!/usr/bin/env bash
# V1 features for the final compiler: structured unchecked reasons, guarded
# switch arms, Shared<T>/Weak<T>, threads with `fnptr`, `else` clauses, named
# enum payload fields, struct patterns and first-class function pointers.
# The syntax forms are final-language only, so they are checked directly
# through `build/harmony`.
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
run_case named-enum-fields 42
run_case struct-patterns 42
run_case named-generic-enum 42
run_case fnptr-basic 42
run_case fnptr-field 42
run_case fnptr-dispatch 42
run_case fnptr-qualified 42

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

# First-class function pointers: signature, arity and argument checks.
"$HC" check "$DIR/fnptr-sig-mismatch.harmony" >"$TMP/fpsig.out" 2>&1
fpsig_rc=$?
if [ "$fpsig_rc" -ne 0 ] && grep -q 'function pointer' "$TMP/fpsig.out"; then
    ok "function pointer rejects a mismatched function signature"
else
    bad "function pointer rejects a mismatched function signature (exit $fpsig_rc)"
fi

"$HC" check "$DIR/fnptr-arity.harmony" >"$TMP/fparity.out" 2>&1
fparity_rc=$?
if [ "$fparity_rc" -ne 0 ] && grep -q 'wrong number of arguments' "$TMP/fparity.out"; then
    ok "indirect call rejects the wrong arity"
else
    bad "indirect call rejects the wrong arity (exit $fparity_rc)"
fi

"$HC" check "$DIR/fnptr-arg-type.harmony" >"$TMP/fparg.out" 2>&1
fparg_rc=$?
if [ "$fparg_rc" -ne 0 ] && grep -q 'TYPE-01' "$TMP/fparg.out"; then
    ok "indirect call rejects a mismatched argument type"
else
    bad "indirect call rejects a mismatched argument type (exit $fparg_rc)"
fi

"$HC" check "$DIR/fnptr-missing-arrow.harmony" >"$TMP/fparrow.out" 2>&1
fparrow_rc=$?
if [ "$fparrow_rc" -ne 0 ] && grep -q 'SYN-05' "$TMP/fparrow.out"; then
    ok "fn type rejects a missing return type"
else
    bad "fn type rejects a missing return type (exit $fparrow_rc)"
fi

"$HC" check "$DIR/fnptr-unknown-type.harmony" >"$TMP/fpunknown.out" 2>&1
fpunknown_rc=$?
if [ "$fpunknown_rc" -ne 0 ] && grep -q 'NAME-01' "$TMP/fpunknown.out"; then
    ok "fn type rejects an unknown parameter type"
else
    bad "fn type rejects an unknown parameter type (exit $fpunknown_rc)"
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

"$HC" check "$DIR/pattern-unknown-field.harmony" >"$TMP/pf.out" 2>&1
pf_rc=$?
if [ "$pf_rc" -ne 0 ] && grep -q 'no such field' "$TMP/pf.out"; then
    ok "struct pattern rejects an unknown field"
else
    bad "struct pattern rejects an unknown field (exit $pf_rc)"
fi

"$HC" check "$DIR/ctor-unknown-field.harmony" >"$TMP/cf.out" 2>&1
cf_rc=$?
if [ "$cf_rc" -ne 0 ] && grep -q 'no such field' "$TMP/cf.out"; then
    ok "named payload constructor rejects an unknown field"
else
    bad "named payload constructor rejects an unknown field (exit $cf_rc)"
fi

"$HC" check "$DIR/pattern-wrong-subject.harmony" >"$TMP/ps.out" 2>&1
ps_rc=$?
if [ "$ps_rc" -ne 0 ] && grep -q 'struct pattern needs a struct or enum' "$TMP/ps.out"; then
    ok "struct pattern rejects a scalar subject"
else
    bad "struct pattern rejects a scalar subject (exit $ps_rc)"
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
