#!/usr/bin/env bash
# harmony-base error-handling tests (the project's "purposely bad code" suite).
#
# Every program under tests/harmony/error-handling/ is deliberately wrong,
# simple or complex. Each is expected to be *rejected* by the type checker
# with the diagnostic code named in its `// WANT: CODE` header line, and the
# compiler must never crash on any of them. A case may name several codes
# (`// WANT: TYPE-01 NAME-01`) when it exercises more than one check; all
# named codes must appear.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
CASES="$ROOT/tests/harmony/error-handling"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ "$(basename "$HB")" = "harmony-base" ]; then V1_LANE=0; else V1_LANE=1; fi

# Documented v0/v1 diagnostic-code divergences, tracked in todo.md as 1.0
# parity items. Both compilers reject these programs; only the code differs.
known_v1_divergence() {
    case "$1:$2" in
        import-missing:NAME-04) return 0;;
        import-missing-2:NAME-04) return 0;;
        many-errors:CASE-01) return 0;;
        *) return 1;;
    esac
}

run_case() {
    local src="$1"
    local name
    name="$(basename "$src" .harmony)"
    local want
    want="$(sed -n 's|^// WANT: *||p' "$src" | head -1)"

    "$HB" check "$src" >"$TMP/out" 2>&1
    local rc=$?
    if [ "$rc" -ge 128 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (accepted; expected rejection)\n' "$name"
        return
    fi
    local missing=""
    local code
    for code in $want; do
        if ! grep -q "$code" "$TMP/out"; then
            if [ "$V1_LANE" -eq 1 ] && known_v1_divergence "$name" "$code"; then
                printf 'DIVERGENCE %s: v1 does not emit %s (legacy does)\n' "$name" "$code"
            else
                missing="$missing $code"
            fi
        fi
    done
    if [ -z "$missing" ]; then
        pass=$((pass + 1))
        printf 'ok   %s (rejected with %s)\n' "$name" "$want"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (missing code(s):%s)\n' "$name" "$missing"
        sed 's/^/     /' "$TMP/out" | head -6
    fi
}

shopt -s nullglob
for src in "$CASES"/*.harmony; do
    run_case "$src"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
