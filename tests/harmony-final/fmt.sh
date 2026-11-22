#!/usr/bin/env bash
# `harmony fmt` gate: one deterministic style, token preservation, comments,
# and idempotence.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
HC="$ROOT/build/harmony"
SRC="$ROOT/tests/harmony-final/fmt/sample.harmony"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$HC" ] || [ ! -x "$HB" ]; then
    echo "error: build harmony and harmony-base first" >&2
    exit 1
fi
cd "$ROOT"

"$HC" fmt "$SRC" >"$TMP/one.harmony" 2>"$TMP/fmt.err"
if [ -s "$TMP/one.harmony" ] && [ ! -s "$TMP/fmt.err" ]; then
    ok "fmt writes only formatted source"
else
    bad "fmt writes only formatted source"
    head -5 "$TMP/fmt.err" | sed 's/^/     /'
fi

"$HC" fmt "$TMP/one.harmony" >"$TMP/two.harmony" 2>/dev/null
if cmp -s "$TMP/one.harmony" "$TMP/two.harmony"; then
    ok "formatting is idempotent"
else
    bad "formatting is idempotent"
    diff "$TMP/one.harmony" "$TMP/two.harmony" | head -12 | sed 's/^/     /'
fi

"$HB" --dump-tokens "$SRC" >"$TMP/src.toks" 2>/dev/null
"$HB" --dump-tokens "$TMP/one.harmony" >"$TMP/fmt.toks" 2>/dev/null
if cmp -s "$TMP/src.toks" "$TMP/fmt.toks"; then
    ok "formatting preserves the token stream"
else
    bad "formatting preserves the token stream"
    diff "$TMP/src.toks" "$TMP/fmt.toks" | head -12 | sed 's/^/     /'
fi

if grep -q '^// A canonical-format fixture' "$TMP/one.harmony" \
    && grep -q 'block comments are preserved' "$TMP/one.harmony"; then
    ok "line and block comments survive"
else
    bad "line and block comments survive"
fi

"$HC" run --jobs=1 "$SRC" >/dev/null 2>/dev/null
src_rc=$?
"$HC" run --jobs=1 "$TMP/one.harmony" >/dev/null 2>/dev/null
fmt_rc=$?
if [ "$src_rc" -eq "$fmt_rc" ]; then
    ok "formatted program keeps its behavior (exit $fmt_rc)"
else
    bad "formatted program keeps its behavior ($src_rc vs $fmt_rc)"
fi

if "$HC" fmt "$TMP/missing.harmony" >"$TMP/missing.out" 2>/dev/null; then
    bad "missing input is a usage error"
else
    ok "missing input is a usage error"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
