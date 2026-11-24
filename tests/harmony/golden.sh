#!/usr/bin/env bash
# harmony-base golden fixtures.
#
# Each case is a directory under `golden/` containing:
#   args            shell words for the compiler invocation (required)
#   exit            expected exit code (required)
#   stdout          expected stdout bytes (required; may be empty)
#   <input files>   any .harmony inputs the args reference
#
# The runner diffs stdout and the exit code byte for byte (§23.13: the report
# *is* a test case). stderr is not compared: it carries driver chatter.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
GOLDEN="$ROOT/tests/harmony/golden"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (HARMONY=$HARMONY; run 'make all' first)" >&2
    exit 1
fi

if [ "$(basename "$HB")" != "harmony-base" ]; then
    # These fixtures pin the legacy compiler's exact CLI surface (--dump-tokens,
    # emit-c) and diagnostic wording. v1 does not implement that surface, and
    # its rendering intentionally differs. AST/IR/diagnostic parity is instead
    # checked against tests/golden/v0.3.3/ by tests/harmony-final/*.py.
    printf 'SKIP legacy golden fixtures (legacy CLI/wording; v1 uses frozen goldens)\n'
    exit 0
fi

for dir in "$GOLDEN"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/args" ] || continue

    args="$(cat "$dir/args")"
    want_exit="$(tr -d ' \n' < "$dir/exit")"

    # Run from the case directory so relative input paths resolve. Capture
    # stdout to a file so the diff is byte-exact (no trailing-newline stripping).
    ( cd "$dir" && $HB $args ) > "$TMP/out" 2>/dev/null
    actual_exit=$?

    if [ "$actual_exit" != "$want_exit" ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want_exit" "$actual_exit"
        continue
    fi
    if ! diff -q "$dir/stdout" "$TMP/out" >/dev/null 2>&1; then
        fail=$((fail + 1))
        printf 'FAIL %s (stdout differs)\n' "$name"
        diff "$dir/stdout" "$TMP/out" | sed 's/^/  /' | head -40
        continue
    fi

    pass=$((pass + 1))
    printf 'ok   %s (exit %s)\n' "$name" "$actual_exit"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
