#!/usr/bin/env bash
# harmony-base aggressive/fuzz tests.
#
# P0 has no language surface yet, so this focuses on driver robustness: the
# compiler must never crash (segfault/abort) on arbitrary bytes, arguments, or
# missing/garbage inputs. Every case must terminate with a defined exit code.
#
# As the lexer/parser land, add input mutation fuzzing here.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# A crash is exit code >= 128 (signal) or the shell's 139 for SIGSEGV.
run_case() {
    local name="$1"; shift
    "$HB" "$@" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -ge 128 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"
    else
        pass=$((pass + 1))
        printf 'ok   %s (exit %s)\n' "$name" "$rc"
    fi
}

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (run 'make harmony-base' first)" >&2
    exit 1
fi

# Random binary garbage as input.
for i in $(seq 1 8); do
    head -c $((RANDOM % 4096 + 1)) /dev/urandom > "$TMP/garbage.harmony"
    run_case "random-garbage-$i" check "$TMP/garbage.harmony"
done

# NUL-heavy input.
head -c 1024 /dev/zero > "$TMP/zeros.harmony"
run_case "all-nul-bytes" check "$TMP/zeros.harmony"

# Very long single line.
python3 -c 'import sys; sys.stdout.write("a" * 200000)' > "$TMP/long.harmony" 2>/dev/null \
    || head -c 200000 /dev/zero | tr '\0' 'a' > "$TMP/long.harmony"
run_case "long-line" check "$TMP/long.harmony"

# Many lines.
yes "let x = 1;" | head -n 50000 > "$TMP/many.harmony"
run_case "many-lines" check "$TMP/many.harmony"

# Assorted argument shapes must not crash.
run_case "no-args"
run_case "empty-subcommand" ""
run_case "dash-only" -
run_case "double-dash" --
run_case "unknown-subcommand" frobnicate "$TMP/long.harmony"
run_case "flag-cluster" -vvvv check "$TMP/long.harmony"
run_case "missing-o-value" -o
run_case "emit-asm" build --emit=asm "$TMP/long.harmony"

# Nonexistent and directory inputs.
run_case "missing-input" check "$TMP/nope.harmony"
run_case "directory-input" check "$TMP"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
