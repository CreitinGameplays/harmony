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
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# A crash is a signal death. A large exit code by itself is not one: `run`
# forwards the compiled program's `main` value mod 256, so exit 241 is a
# legitimate result. The driver names a signal death on stderr.
run_case() {
    local name="$1"; shift
    "$HB" "$@" >/dev/null 2>"$TMP/err"
    local rc=$?
    if [ "$rc" -ge 128 ] && grep -q "killed by signal" "$TMP/err"; then
        fail=$((fail + 1))
        printf 'FAIL %s (crashed, exit %s)\n' "$name" "$rc"
    else
        pass=$((pass + 1))
        printf 'ok   %s (exit %s)\n' "$name" "$rc"
    fi
}

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (HARMONY=$HARMONY; run 'make all' first)" >&2
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
run_case "emit-c-json" build --format=json "$TMP/long.harmony"
run_case "explain-no-code" explain
run_case "explain-junk" explain "MOVE-@@["
run_case "audit-junk-args" audit "$TMP/long.harmony"

# Nonexistent and directory inputs.
run_case "missing-input" check "$TMP/nope.harmony"
run_case "directory-input" check "$TMP"

# Concurrent `run` invocations must not collide. The driver used fixed temp
# paths (/tmp/harmony-base.bin), so one invocation's clang truncated the
# binary another had just linked and the loser's exec failed with 127.
# Campaigns compile in parallel by design, so this is a real bug class: every
# one of N concurrent runs must report the program's own exit status.
cat > "$TMP/concurrent.harmony" <<'EOF'
fn main() -> i32 { return 1033658417137; }
EOF
conc_bad=0
pids=""
for i in $(seq 1 12); do
    ( "$HB" run "$TMP/concurrent.harmony" >/dev/null 2>&1; echo $? >"$TMP/rc.$i" ) &
    pids="$pids $!"
done
for p in $pids; do wait "$p"; done
for i in $(seq 1 12); do
    rc="$(cat "$TMP/rc.$i" 2>/dev/null)"
    # 241 == 1033658417137 mod 256; anything else means the runs clobbered
    # one another (127 = exec failed because the binary vanished).
    [ "$rc" = "241" ] || conc_bad=$((conc_bad + 1))
done
if [ "$conc_bad" -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   concurrent-run-isolation (12/12 correct)\n'
else
    fail=$((fail + 1)); printf 'FAIL concurrent-run-isolation (%s/12 wrong exit)\n' "$conc_bad"
fi

# `check` must not print an AST: `--dump-ast` defaults off, but its flag lived
# in a stack-local `Options` that parse_options forgot to initialize, so it
# read stack garbage (a valgrind sample caught it: "Conditional jump depends
# on uninitialised value" in pipeline_run). A plain output comparison does NOT
# detect this — the garbage often happens to be zero — so the check is
# valgrind's uninitialised-value analysis. Skipped when valgrind is absent.
cat > "$TMP/noast.harmony" <<'EOF'
fn main() -> i32 { return 0; }
EOF
if command -v valgrind >/dev/null 2>&1; then
    "$HB" check "$TMP/noast.harmony" >"$TMP/noast.out" 2>&1
    if valgrind -q --error-exitcode=99 --leak-check=no \
           "$HB" check "$TMP/noast.harmony" >"$TMP/noast.out" 2>"$TMP/noast.err"
    then
        if grep -qx "program" "$TMP/noast.out"; then
            fail=$((fail + 1)); printf 'FAIL check-no-uninit-options (printed an AST)\n'
        else
            pass=$((pass + 1)); printf 'ok   check-no-uninit-options (valgrind clean)\n'
        fi
    else
        fail=$((fail + 1)); printf 'FAIL check-no-uninit-options (valgrind reported uninitialised reads)\n'
        sed 's/^/     /' "$TMP/noast.err" | head -4
    fi
else
    printf 'skip check-no-uninit-options (valgrind not installed)\n'
fi

# The same uninitialised-`Options` class, caught without valgrind: every
# subcommand must behave identically across repeated runs and flag shapes.
# `--dump-ast` firing at random would show up as an AST on some invocations.
ast_leak=0
for i in $(seq 1 6); do
    case "$i" in
        1) "$HB" check "$TMP/noast.harmony" ;;
        2) "$HB" -v check "$TMP/noast.harmony" ;;
        3) "$HB" check --format=json "$TMP/noast.harmony" ;;
        4) "$HB" --all check "$TMP/noast.harmony" ;;
        5) "$HB" check --format=line "$TMP/noast.harmony" ;;
        6) "$HB" --strict check "$TMP/noast.harmony" ;;
    esac >"$TMP/noast.out" 2>&1
    if grep -qx "program" "$TMP/noast.out"; then
        ast_leak=$((ast_leak + 1))
    fi
done
if [ "$ast_leak" -eq 0 ]; then
    pass=$((pass + 1)); printf 'ok   check-does-not-dump-ast (6/6 clean)\n'
else
    fail=$((fail + 1)); printf 'FAIL check-does-not-dump-ast (%s/6 leaked an AST)\n' "$ast_leak"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
