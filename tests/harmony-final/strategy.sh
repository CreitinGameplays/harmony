#!/usr/bin/env bash
# §19.6 test-strategy gates that fit the implemented compiler surface:
# golden snapshots for all renderers and the reference-interpreter oracle.
# Sanitizer fuzzing of generated C output is deliberately not included: the
# C11 backend is the one item explicitly out of scope for this pass.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
DIR="$ROOT/tests/harmony-final/snapshots"
SRC="tests/harmony-final/diag/fold.harmony"
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

snapshot() {
    local name="$1" golden="$2"; shift 2
    "$HC" check "$@" "$SRC" >"$TMP/$name.out" 2>&1
    if cmp -s "$TMP/$name.out" "$DIR/$golden"; then
        ok "snapshot $name"
    else
        bad "snapshot $name"
        diff "$DIR/$golden" "$TMP/$name.out" | head -12 | sed 's/^/     /'
    fi
}

snapshot pretty move.pretty.golden
snapshot ascii move.ascii.golden --ascii
snapshot json move.json.golden --format=json

if python3 "$ROOT/tests/harmony-final/interpreter.py" >"$TMP/interp.out" 2>&1; then
    ok "reference interpreter agrees with the compiler"
else
    bad "reference interpreter agrees with the compiler"
    tail -8 "$TMP/interp.out" | sed 's/^/     /'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
