#!/usr/bin/env bash
# c2x-seed determinism regression.
#
# Guards the fix for the PID-in-FILE-symbol bug: c2x-seed used to feed nasm a
# PID-unique temp .asm path, and nasm records that path in the object's FILE
# symbol, which `ld` copies into the final executable's .strtab. So two builds
# of the *same* source produced binaries differing in those bytes.
#
# The compiler now feeds nasm the stable "/dev/stdin" path. This test builds
# one source four times and requires the four binaries to be byte-identical.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED="$ROOT/build/c2x-seed"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ ! -x "$SEED" ]; then
    echo "error: $SEED not built (run 'bash build.sh' first)" >&2
    exit 1
fi

cat > "$TMP/prog.c2" <<'EOF'
int fib(int n) {
    if (n < 2) { return n; }
    return fib(n - 1) + fib(n - 2);
}
int main(void) {
    return fib(10) & 0xFF;
}
EOF

for i in 1 2 3 4; do
    "$SEED" -o "$TMP/bin$i" "$TMP/prog.c2" >/dev/null 2>&1
done

if [ ! -f "$TMP/bin1" ]; then
    fail=$((fail + 1))
    printf 'FAIL build (no output produced)\n'
else
    for i in 2 3 4; do
        if cmp -s "$TMP/bin1" "$TMP/bin$i"; then
            pass=$((pass + 1))
            printf 'ok   build %s is byte-identical to build 1\n' "$i"
        else
            fail=$((fail + 1))
            printf 'FAIL build %s differs from build 1\n' "$i"
            cmp -l "$TMP/bin1" "$TMP/bin$i" | head -5 | sed 's/^/     /'
        fi
    done
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
