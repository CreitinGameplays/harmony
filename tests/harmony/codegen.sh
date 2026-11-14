#!/usr/bin/env bash
# harmony-base LLVM backend tests (docs/harmony.md §19.4, §19.6 accept suite).
#
# Each case is a small .harmony program. It is compiled and run through the
# driver and its exit status is compared with the `// EXPECT: <n>` header.
# A case may also set `// EXPECT-TRAP: <code>` for a program that must trap
# (exit 70) instead. The generated IR must contain `// IR: <substr>` when
# given. All programs stay inside the M1 slice (scalars, functions, control
# flow, trapping arithmetic).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
CASES="$ROOT/tests/harmony/codegen"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
    local src="$1"
    local name
    name="$(basename "$src" .harmony)"
    local expect trap irwant outwant
    expect="$(sed -n 's|^// EXPECT: *\([0-9]*\).*|\1|p' "$src" | head -1)"
    trap="$(sed -n 's|^// EXPECT-TRAP: *\([A-Z0-9-]*\).*|\1|p' "$src" | head -1)"
    irwant="$(sed -n 's|^// IR: *||p' "$src" | head -1)"
    outwant="$(sed -n 's|^// EXPECT-OUT: *||p' "$src" | head -1)"

    "$HB" run "$src" >"$TMP/out" 2>"$TMP/err"
    local rc=$?
    if [ "$rc" -ge 128 ]; then
        fail=$((fail + 1)); printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"; return
    fi
    if [ -n "$trap" ]; then
        if [ "$rc" = "70" ] && grep -q "$trap" "$TMP/err"; then
            pass=$((pass + 1)); printf 'ok   %s (trap %s)\n' "$name" "$trap"
        else
            fail=$((fail + 1)); printf 'FAIL %s (want trap %s exit 70, got exit %s)\n' "$name" "$trap" "$rc"
            sed 's/^/     /' "$TMP/err" | head -3
        fi
        return
    fi
    if [ "$rc" = "$expect" ]; then
        pass=$((pass + 1)); printf 'ok   %s (exit %s)\n' "$name" "$rc"
    else
        fail=$((fail + 1)); printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$expect" "$rc"
        sed 's/^/     /' "$TMP/err" | head -3
    fi
    # A program may assert its stdout: every `// EXPECT-OUT: <line>` must
    # match a line in stdout.
    if [ -n "$outwant" ]; then
        local oline okall=1
        while IFS= read -r oline; do
            [ -z "$oline" ] && continue
            if ! grep -qF "$oline" "$TMP/out"; then
                okall=0
                fail=$((fail + 1)); printf 'FAIL %s (stdout lacks %s)\n' "$name" "$oline"
                sed 's/^/     /' "$TMP/out" | head -5
                break
            fi
        done <<EOF
$(sed -n 's|^// EXPECT-OUT: *||p' "$src")
EOF
        if [ "$okall" = "1" ]; then
            pass=$((pass + 1)); printf 'ok   %s (stdout matches)\n' "$name"
        fi
    fi
    if [ -n "$irwant" ]; then
        "$HB" emit-llvm "$src" >"$TMP/ir" 2>/dev/null
        if grep -q "$irwant" "$TMP/ir"; then
            pass=$((pass + 1)); printf 'ok   %s (ir contains %s)\n' "$name" "$irwant"
        else
            fail=$((fail + 1)); printf 'FAIL %s (ir lacks %s)\n' "$name" "$irwant"
        fi
    fi
}

shopt -s nullglob
for src in "$CASES"/*.harmony; do
    run_case "$src"
done

# Determinism: one input, two emit-llvm runs, byte-identical output.
if [ -f "$CASES/arithmetic.harmony" ]; then
    "$HB" emit-llvm "$CASES/arithmetic.harmony" >"$TMP/d1" 2>/dev/null
    "$HB" emit-llvm "$CASES/arithmetic.harmony" >"$TMP/d2" 2>/dev/null
    if diff -q "$TMP/d1" "$TMP/d2" >/dev/null; then
        pass=$((pass + 1)); printf 'ok   emit-llvm is deterministic\n'
    else
        fail=$((fail + 1)); printf 'FAIL emit-llvm is deterministic\n'
    fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
