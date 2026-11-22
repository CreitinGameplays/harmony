#!/usr/bin/env bash
# M2 ownership gate for the final compiler: moves, copy, clone, cleanup and
# drop flags. These semantics are final-compiler-only, so the programs are run
# directly through build/harmony.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HC="$ROOT/build/harmony"
DIR="$ROOT/tests/harmony-final/m2"
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

run_case basic-move 42
run_case copy-keeps-source 42
run_case clone 42
run_case vec-drop 42
run_case cleanup-order 42
run_case conditional-move-flag 0
run_case reinit 2

# Cleanup runs exactly once, in reverse declaration order.
if "$HC" run "$DIR/cleanup-order.harmony" 2>/dev/null \
    | tr '\n' ' ' | grep -q 'drop 2 drop 1 '; then
    ok "cleanup runs in reverse declaration order"
else
    bad "cleanup order"
fi

# A conditionally moved value is dropped once at the callee and once at the
# scope end of the path where it was not moved -- never twice on one path.
if [ "$( "$HC" run "$DIR/conditional-move-flag.harmony" 2>/dev/null | grep -c 'drop 7' )" -eq 2 ]; then
    ok "drop flag clears a conditionally moved owner"
else
    bad "drop flag double-dropped or leaked"
fi

reject err-use-after-move MOVE-01
reject err-conditional-move MOVE-01
reject err-loop-move MOVE-02
reject err-partial-move MOVE-04
reject err-invalid-copy TYPE-05
reject err-copy-cleanup TYPE-05
reject err-direct-cleanup DROP-01
reject err-bound TYPE-06
reject err-clone-mutref TYPE-05

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
