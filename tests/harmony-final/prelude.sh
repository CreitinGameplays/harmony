#!/usr/bin/env bash
# library/core/prelude.hr gate: the prelude free functions that the current
# backend can express as ordinary library code (§15.1, §19.8.2).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
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

"$HC" run --jobs=1 tests/harmony-final/prelude-probe.harmony >/dev/null 2>/dev/null
rc=$?
if [ "$rc" -eq 10 ]; then
    ok "swap and replace run as library functions (exit 10)"
else
    bad "swap and replace run as library functions (got $rc)"
fi

if "$HC" --all check --format=line tests/harmony-final/prelude-probe.harmony \
        >"$TMP/check.out" 2>&1 \
    && ! grep -q 'stop\[' "$TMP/check.out"; then
    ok "prelude imports without compiler errors"
else
    bad "prelude imports without compiler errors"
    grep 'stop\[' "$TMP/check.out" | head -5 | sed 's/^/     /'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
