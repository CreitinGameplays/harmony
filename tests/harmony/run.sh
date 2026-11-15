#!/usr/bin/env bash
# harmony-base driver smoke tests.
#
# These exercise the pipeline end to end at the M0 level: argument handling,
# source loading, the lexer stub, the diagnostic renderers, and exit codes
# (docs/harmony.md §16.6, §19.5). As later milestones land, this script grows
# real language tests.
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

# check on a real file -> success, and a clean build prints nothing (§16.6).
out="$("$HB" check "$TMP/hello.harmony" 2>/dev/null)"
check "check hello exits 0" 0 $?
if [ -z "$out" ]; then
    pass=$((pass + 1)); printf 'ok   clean check prints nothing\n'
else
    fail=$((fail + 1)); printf 'FAIL clean check prints nothing\n'
fi

# check on an empty file -> success (lexer stub emits EOF).
"$HB" check "$TMP/empty.harmony" >/dev/null 2>&1
check "check empty exits 0" 0 $?

# Missing file -> usage/I-O error (§16.6).
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

# Codegen paths. The LLVM backend works for the M1 slice; emit-c is still M7.
# The LLVM backend works for the M1 slice: emit-llvm prints IR, build
# produces an executable, run executes it. emit-c is still M7.
"$HB" emit-llvm "$TMP/hello.harmony" >"$TMP/ir.ll" 2>/dev/null
check "emit-llvm exits 0" 0 $?
if grep -q "@harmony_main" "$TMP/ir.ll"; then
    pass=$((pass + 1)); printf 'ok   emit-llvm defines harmony_main\n'
else
    fail=$((fail + 1)); printf 'FAIL emit-llvm defines harmony_main\n'
fi
"$HB" build "$TMP/hello.harmony" -o "$TMP/hello.bin" >/dev/null 2>&1
check "build exits 0" 0 $?
if [ -x "$TMP/hello.bin" ]; then
    pass=$((pass + 1)); printf 'ok   build produces an executable\n'
else
    fail=$((fail + 1)); printf 'FAIL build produces an executable\n'
fi
# emit-c is the cross-check backend, still M7: an honest ICE-01 with a fix.
"$HB" emit-c "$TMP/hello.harmony" 2>/dev/null | grep -q "ICE-01"
if [ $? -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   emit-c stops with ICE-01 (M7)\n'
else
    fail=$((fail + 1)); printf 'FAIL emit-c stops with ICE-01 (M7)\n'
fi

# The stop renders in every format and names its code.
"$HB" --format=line emit-c "$TMP/hello.harmony" 2>/dev/null | grep -q "stop\[ICE-01\]"
if [ $? -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   --format=line renders one line\n'
else
    fail=$((fail + 1)); printf 'FAIL --format=line renders one line\n'
fi
"$HB" --format=json emit-c "$TMP/hello.harmony" 2>/dev/null | grep -q '"code": "ICE-01"'
if [ $? -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   --format=json renders an object\n'
else
    fail=$((fail + 1)); printf 'FAIL --format=json renders an object\n'
fi

# A clean build with --format=json prints nothing at all.
json_out="$("$HB" --format=json check "$TMP/hello.harmony" 2>/dev/null)"
check "clean json check exits 0" 0 $?
if [ -z "$json_out" ]; then
    pass=$((pass + 1)); printf 'ok   clean json check prints nothing\n'
else
    fail=$((fail + 1)); printf 'FAIL clean json check prints nothing\n'
fi

# Unknown flag -> usage error.
"$HB" --nope check "$TMP/hello.harmony" >/dev/null 2>&1
check "unknown flag exits 2" 2 $?

# Bad -O level -> its own usage error (§19.5), not "unknown flag".
"$HB" check -O4 "$TMP/hello.harmony" >/dev/null 2>&1
check "bad -O level exits 2" 2 $?
"$HB" check -O4 "$TMP/hello.harmony" 2>&1 | grep -q "usage.bad-opt"
if [ $? -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   bad -O level names usage.bad-opt\n'
else
    fail=$((fail + 1)); printf 'FAIL bad -O level names usage.bad-opt\n'
fi

# Every optimization level is accepted on check (§19.5); -O2 is the default.
for lvl in -O0 -O1 -O2 -O3 -Os -Oz -Og -Ofast -O; do
    "$HB" check "$lvl" "$TMP/hello.harmony" >/dev/null 2>&1
    check "$lvl check exits 0" 0 $?
done

# Bad --format value -> usage error.
"$HB" --format=bogus check "$TMP/hello.harmony" >/dev/null 2>&1
check "bad --format exits 2" 2 $?

# Too many inputs -> usage error.
"$HB" check "$TMP/hello.harmony" "$TMP/hello.harmony" >/dev/null 2>&1
check "two inputs exits 2" 2 $?

# explain <known code> prints a lesson and exits 0 (§16.8).
"$HB" explain ICE-01 >/dev/null 2>&1
check "explain ICE-01 exits 0" 0 $?

# explain <unknown code> is a usage error.
"$HB" explain MOVE-99 >/dev/null 2>&1
check "explain unknown code exits 2" 2 $?

# explain with no code is a usage error.
"$HB" explain >/dev/null 2>&1
check "explain missing code exits 2" 2 $?

# audit lists the unchecked surface (§13.6, §13.8). With no input the
# listing is empty; with an input it reports each `unchecked` block / fn.
audit_out="$("$HB" audit 2>/dev/null)"
check "audit exits 0" 0 $?
if echo "$audit_out" | grep -q "unchecked audit - 0 sites"; then
    pass=$((pass + 1)); printf 'ok   audit (no input) prints the empty listing\n'
else
    fail=$((fail + 1)); printf 'FAIL audit (no input) prints the empty listing\n'
fi
# A real site: the extern-unchecked codegen case has one block.
audit_out="$("$HB" audit "$ROOT/tests/harmony/codegen/extern-unchecked.harmony" 2>/dev/null)"
check "audit <file> exits 0" 0 $?
if echo "$audit_out" | grep -q "1 sites" && echo "$audit_out" | grep -q "block"; then
    pass=$((pass + 1)); printf 'ok   audit <file> lists the unchecked block\n'
else
    fail=$((fail + 1)); printf 'FAIL audit <file> lists the unchecked block\n'
fi

# --strict / --all / --deny-unchecked parse and do not disturb a clean check.
"$HB" --strict check "$TMP/hello.harmony" >/dev/null 2>&1
check "--strict clean exits 0" 0 $?
"$HB" --all check "$TMP/hello.harmony" >/dev/null 2>&1
check "--all clean exits 0" 0 $?
"$HB" --deny-unchecked check "$TMP/hello.harmony" >/dev/null 2>&1
check "--deny-unchecked clean exits 0" 0 $?

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
