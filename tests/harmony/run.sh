#!/usr/bin/env bash
# harmony-base driver smoke tests (P0).
#
# These exercise the pipeline end to end at the P0 level: argument handling,
# source loading, the lexer stub, and exit codes. As later phases land, this
# script grows real language tests.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
        printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"
    fi
}

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (run 'make harmony-base' first)" >&2
    exit 1
fi

printf 'fn main() {\n    let x = 1;\n}\n' > "$TMP/hello.harmony"
: > "$TMP/empty.harmony"

# No arguments -> usage error.
"$HB" >/dev/null 2>&1
check "no arguments exits 2" 2 $?

# --help / -h -> usage error (there is no help text yet, exit is usage).
"$HB" --help >/dev/null 2>&1
check "--help exits 2" 2 $?

# check on a real file -> success.
"$HB" check "$TMP/hello.harmony" >/dev/null 2>&1
check "check hello exits 0" 0 $?

# check on an empty file -> success (lexer stub emits EOF).
"$HB" check "$TMP/empty.harmony" >/dev/null 2>&1
check "check empty exits 0" 0 $?

# Missing file -> usage error.
"$HB" check "$TMP/does-not-exist.harmony" >/dev/null 2>&1
check "check missing file exits 2" 2 $?

# Verbose output goes to stderr but exit stays 0.
"$HB" -v check "$TMP/hello.harmony" >/dev/null 2>"$TMP/v.txt"
check "verbose check exits 0" 0 $?
if grep -q "read" "$TMP/v.txt"; then
    pass=$((pass + 1)); printf 'ok   verbose prints byte count\n'
else
    fail=$((fail + 1)); printf 'FAIL verbose prints byte count\n'
fi

# Unimplemented backend -> internal error.
"$HB" build --emit=c "$TMP/hello.harmony" >/dev/null 2>&1
check "--emit=c exits 70" 70 $?

# Unknown flag -> usage error.
"$HB" --nope check "$TMP/hello.harmony" >/dev/null 2>&1
check "unknown flag exits 2" 2 $?

# Too many inputs -> usage error.
"$HB" check "$TMP/hello.harmony" "$TMP/hello.harmony" >/dev/null 2>&1
check "two inputs exits 2" 2 $?

# --explain <known id> prints a page and exits 0.
"$HB" --explain compiler.internal >/dev/null 2>&1
check "--explain known id exits 0" 0 $?

# --explain <unknown id> is a usage error.
"$HB" --explain no.such-id >/dev/null 2>&1
check "--explain unknown id exits 2" 2 $?

# --explain with no id is a usage error.
"$HB" --explain >/dev/null 2>&1
check "--explain missing id exits 2" 2 $?

# --report=seams on a clean file lists no seams and exits 0.
"$HB" --report=seams check "$TMP/hello.harmony" >/dev/null 2>&1
check "--report=seams clean exits 0" 0 $?

# --forbid accepts the two known targets.
"$HB" --forbid=unchecked check "$TMP/hello.harmony" >/dev/null 2>&1
check "--forbid=unchecked exits 0" 0 $?
"$HB" --forbid=keep check "$TMP/hello.harmony" >/dev/null 2>&1
check "--forbid=keep exits 0" 0 $?

# --forbid with an unknown target is a usage error.
"$HB" --forbid=bogus check "$TMP/hello.harmony" >/dev/null 2>&1
check "--forbid=bogus exits 2" 2 $?

# --max-faults accepts 0 (see all) and an explicit cap without failing.
"$HB" --max-faults=0 check "$TMP/hello.harmony" >/dev/null 2>&1
check "--max-faults=0 exits 0" 0 $?
"$HB" --max-faults=5 check "$TMP/hello.harmony" >/dev/null 2>&1
check "--max-faults=5 exits 0" 0 $?

# --allow list parses and does not disturb a clean build.
"$HB" --allow=seam.no-reason,unchecked.raw-escapes check "$TMP/hello.harmony" >/dev/null 2>&1
check "--allow list exits 0" 0 $?

# A clean build with --report=json prints nothing at all (§23.9).
json_out="$("$HB" --report=json check "$TMP/hello.harmony" 2>/dev/null)"
if [ -z "$json_out" ]; then
    pass=$((pass + 1)); printf 'ok   clean json build prints nothing\n'
else
    fail=$((fail + 1)); printf 'FAIL clean json build prints nothing\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
