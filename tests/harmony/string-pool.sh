#!/usr/bin/env bash
# The LLVM string-literal pool must grow past 1024 entries. The old fixed
# table made every later literal alias `@.str.0`, which corrupted the
# compiler's own `--version` path once the driver grew large enough.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$HB" ]; then
    echo "error: $HB not built" >&2
    exit 1
fi

SRC="$TMP/many-strings.harmony"
{
    echo 'fn main() -> i32 {'
    for i in $(seq 0 1099); do
        echo "let s$i = \"literal-$i\";"
    done
    echo 'return 42;'
    echo '}'
} > "$SRC"

"$HB" emit-llvm "$SRC" > "$TMP/out.ll" 2>"$TMP/err" || {
    echo "FAIL string pool: emit-llvm failed"
    head -10 "$TMP/err" | sed 's/^/     /'
    exit 1
}

globals=$(grep -c '^@\.str\.' "$TMP/out.ll" || true)
distinct=$(grep -o '^@\.str\.[0-9]*' "$TMP/out.ll" | sort -u | wc -l)
if [ "$globals" -ge 1100 ] && [ "$distinct" -ge 1100 ]; then
    printf 'ok   string pool grows past 1024 (%s globals)\n' "$globals"
    exit 0
fi
printf 'FAIL string pool (got %s globals, %s distinct)\n' "$globals" "$distinct"
exit 1
