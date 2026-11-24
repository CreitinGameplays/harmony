#!/usr/bin/env bash
# R7 driver smoke and self-host gate.
#
# The `harmony` binary must behave like harmony-base for the driver surface we
# support, and compiling the compiler with itself must be byte-identical to
# compiling it with harmony-base.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$HB" ] || [ ! -x "$HC" ]; then
    echo "error: build HARMONY=$HARMONY and ORACLE=$ORACLE first" >&2
    exit 1
fi

cd "$ROOT"

# --version reports the repository stamp verbatim.
want="harmony $(cat VERSION)"
got="$($HC --version 2>/dev/null)"
if [ "$got" = "$want" ]; then ok "driver --version"; else
    bad "driver --version (got '$got', want '$want')"
fi

# explain and audit are rendered from structured data; compare exact bytes.
if "$HB" explain CONST-01 > "$TMP/explain.hb" 2>/dev/null \
   && "$HC" explain CONST-01 > "$TMP/explain.hc" 2>/dev/null \
   && cmp -s "$TMP/explain.hb" "$TMP/explain.hc"; then
    ok "driver explain matches harmony-base"
else bad "driver explain matches harmony-base"; fi

AUDIT_SRC="tests/harmony/codegen/unchecked-fn.harmony"
if "$HB" audit --format=json "$AUDIT_SRC" > "$TMP/audit.hb" 2>/dev/null \
   && "$HC" audit --format=json "$AUDIT_SRC" > "$TMP/audit.hc" 2>/dev/null \
   && cmp -s "$TMP/audit.hb" "$TMP/audit.hc"; then
    ok "driver audit matches harmony-base"
else
    bad "driver audit matches harmony-base"
    diff "$TMP/audit.hb" "$TMP/audit.hc" | head -20 | sed 's/^/     /'
fi

SRC="tests/harmony/codegen/return-constant.harmony"
if "$HB" emit-llvm "$SRC" > "$TMP/ir.hb" 2>/dev/null \
   && "$HC" emit-llvm "$SRC" > "$TMP/ir.hc" 2>/dev/null \
   && cmp -s "$TMP/ir.hb" "$TMP/ir.hc"; then
    ok "driver emit-llvm matches harmony-base"
else bad "driver emit-llvm matches harmony-base"; fi

# build must produce an executable without running it; run must execute it.
if "$HC" build "$SRC" -o "$TMP/built" >/dev/null 2>&1 \
   && [ -x "$TMP/built" ]; then
    ok "driver build produces an executable"
else bad "driver build produces an executable"; fi
"$HC" run "$SRC" >/dev/null 2>&1
run_rc=$?
if [ "$run_rc" -eq 42 ]; then
    ok "driver run returns the program exit code"
else bad "driver run returns the program exit code (got $run_rc)"; fi

# Rejections still use the stable diagnostic code.
ERR="tests/harmony/error-handling/type-mismatch-simple.harmony"
"$HC" check "$ERR" > "$TMP/err.out" 2>/dev/null
check_rc=$?
if [ "$check_rc" -ne 0 ] && grep -q 'TYPE-01' "$TMP/err.out"; then
    ok "driver check reports TYPE-01"
else bad "driver check reports TYPE-01"; fi

# Self-host: `make harmony` builds a stage-0 binary with harmony-base and
# then rebuilds the canonical stage 1 with itself. Stage 2 is built by stage 1
# and stage 3 by stage 2. All three canonical binaries must be identical.
if "$HC" build harmony/main.hr -o "$TMP/stage2" >/dev/null 2>&1 \
   && "$TMP/stage2" build harmony/main.hr -o "$TMP/stage3" >/dev/null 2>&1 \
   && cmp -s "$HC" "$TMP/stage2" && cmp -s "$TMP/stage2" "$TMP/stage3"; then
    ok "self-host is byte-deterministic (stage 1 == 2 == 3)"
else bad "self-host is byte-deterministic (stage 1 == 2 == 3)"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
