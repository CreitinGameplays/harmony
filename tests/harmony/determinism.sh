#!/usr/bin/env bash
# harmony-base determinism test (docs/harmony.md §19.1: the C backend must be
# byte-reproducible). Same input -> identical output bytes: no timestamps, no
# temp paths, no random state, stable symbol names.
#
# M0 has no codegen yet, so the artifacts checked today are diagnostic output
# (pretty/line/json) and the compiler binary itself. As the C backend lands
# (M1), add `emit-c` output here.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (run 'make harmony-base' first)" >&2
    exit 1
fi

# The compiler binary itself must be byte-identical across rebuilds (no
# timestamps or absolute paths embedded in the build). This is the strongest
# determinism guarantee we can make today.
compare_bytes() {
    local name="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then
        pass=$((pass + 1))
        printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (bytes differ)\n' "$name"
        diff <(xxd "$a" | head -20) <(xxd "$b" | head -20) | head -20 | sed 's/^/  /'
    fi
}

# Rebuild the compiler from scratch twice and compare the binaries.
# (Uses a private build dir so the main build/ stays put.)
BUILD1="$TMP/b1"; BUILD2="$TMP/b2"
mkdir -p "$BUILD1" "$BUILD2"
( cd "$ROOT" && make clean >/dev/null 2>&1 )
( cd "$ROOT" && make harmony-base >/dev/null 2>&1 && cp build/harmony-base "$BUILD1/hb" )
( cd "$ROOT" && make clean >/dev/null 2>&1 )
( cd "$ROOT" && make harmony-base >/dev/null 2>&1 && cp build/harmony-base "$BUILD2/hb" )

if [ -f "$BUILD1/hb" ] && [ -f "$BUILD2/hb" ]; then
    compare_bytes "compiler binary is byte-identical across rebuilds" \
        "$BUILD1/hb" "$BUILD2/hb"
else
    fail=$((fail + 1))
    printf 'FAIL compiler rebuild (missing artifact)\n'
fi

# Diagnostic output must be identical run to run, in every format (§16.7).
cat > "$TMP/src.harmony" <<'EOF'
fn main() {
    let x = 1;
}
EOF

for mode in pretty line json; do
    "$HB" --format=$mode build "$TMP/src.harmony" > "$TMP/$mode.1" 2>/dev/null
    "$HB" --format=$mode build "$TMP/src.harmony" > "$TMP/$mode.2" 2>/dev/null
    compare_bytes "diagnostic output ($mode) is identical run to run" "$TMP/$mode.1" "$TMP/$mode.2"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
