#!/usr/bin/env bash
# harmony-base scale tests: the compiler must handle programs far larger than
# its own fixed tables used to allow.
#
# Two regressions this guards (both were silent or confusing before the fix):
#   - the function table was a fixed `g_fn_decl[1024]`; the 1025th function was
#     never registered, so its return type resolved to `void` and it emitted as
#     `define void @...` (clang then rejected the IR, "value doesn't match
#     function result type"). The table is resizable now, so the last function
#     keeps its real signature.
#   - the compiler arena was a fixed 16 MiB BSS block; a program of ~150
#     branch-heavy functions exhausted it (ICE-01). The arena now spills to
#     OS-backed chunks, so the ceiling is gone.
#
# The programs are generated here (no checked-in 1000-line blob). Each case
# must (a) emit IR with the last function's real `i32` signature and (b) build
# and run to the right exit code.
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

# gen_program <path> <nfunctions>: N trivial functions plus a main that chains
# them (x -> x+1), so the running value after N calls is N and the exit code is
# N mod 256. Trivial bodies keep the clang step fast while still pushing the
# function table (and, at a larger N, the arena) past its old limits.
gen_program() {
    local src="$1" n="$2"
    local i=0
    {
        while [ "$i" -lt "$n" ]; do
            printf 'fn gf%d(x: i32) -> i32 { return x + 1; }\n' "$i"
            i=$((i + 1))
        done
        printf 'fn main() -> i32 {\n  let mut s = 0;\n'
        i=0
        while [ "$i" -lt "$n" ]; do
            printf '  s = gf%d(s);\n' "$i"
            i=$((i + 1))
        done
        printf '  return s %% 256;\n}\n'
    } > "$src"
}

# run_scale <name> <nfunctions>
run_scale() {
    local name="$1" n="$2"
    local want=$((n % 256))
    local last=$((n - 1))
    local src="$TMP/$name.harmony"
    gen_program "$src" "$n"

    # (a) The IR must carry the last function's real signature. Before the fix
    # it was `define void @harmony__gf$last(...)` (the checker never resolved
    # its return type) and clang rejected the module.
    if ! "$HB" emit-llvm "$src" >"$TMP/$name.ll" 2>"$TMP/$name.err"; then
        fail=$((fail + 1)); printf 'FAIL %s (emit-llvm failed)\n' "$name"
        sed 's/^/     /' "$TMP/$name.err" | head -3; return
    fi
    if ! grep -q "define i32 @harmony__gf$last(" "$TMP/$name.ll"; then
        fail=$((fail + 1)); printf 'FAIL %s (function %s lost its i32 signature)\n' "$name" "$last"
        return
    fi

    # (b) And it must run to the right exit code.
    "$HB" run "$src" >/dev/null 2>"$TMP/$name.err"
    local got=$?
    if [ "$got" -ge 128 ]; then
        fail=$((fail + 1)); printf 'FAIL %s (crashed, exit %s)\n' "$name" "$got"; return
    fi
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); printf 'ok   %s (%s fns, exit %s)\n' "$name" "$n" "$got"
    else
        fail=$((fail + 1)); printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"
        sed 's/^/     /' "$TMP/$name.err" | head -3
    fi
}

# run_arena <name> <nfunctions>: N functions with a branch-heavy body, so the
# emitted IR is large (~1.4 MB at N = 200). The old fixed 16 MiB arena failed
# at ~150 such functions with `arena exhausted (ICE-01)`; this must emit
# cleanly now. Only `emit-llvm` is checked (compiling the ~MB of IR is slow and
# the regression is in the emitter, not clang).
run_arena() {
    local name="$1" n="$2"
    local src="$TMP/$name.harmony"
    local i=0
    {
        while [ "$i" -lt "$n" ]; do
            printf 'fn gf%d(x: i32) -> i32 {\n  let mut s = x;\n' "$i"
            local j=0
            while [ "$j" -lt 8 ]; do
                printf '  if (s > %d) { s = s + 1; } else { s = s - 1; }\n' "$j"
                j=$((j + 1))
            done
            printf '  return s;\n}\n'
            i=$((i + 1))
        done
        printf 'fn main() -> i32 { return gf0(0); }\n'
    } > "$src"

    if ! "$HB" emit-llvm "$src" >"$TMP/$name.ll" 2>"$TMP/$name.err"; then
        fail=$((fail + 1)); printf 'FAIL %s (emit-llvm failed)\n' "$name"
        sed 's/^/     /' "$TMP/$name.err" | head -3; return
    fi
    local bytes
    bytes="$(wc -c < "$TMP/$name.ll")"
    pass=$((pass + 1)); printf 'ok   %s (%s fns, %s bytes of IR)\n' "$name" "$n" "$bytes"
}

# 1030 crosses the old 1024-function table cap by a little; 1300 pushes further
# so the fix is a range, not one lucky point. Both are also far past the old
# 16 MiB arena ceiling.
run_scale "just-past-1024" 1030
run_scale "past-1024-fns" 1300
# Branch-heavy bodies: ~1.4 MB of IR, which the old 16 MiB arena could not hold
# past ~150 functions.
run_arena "arena-past-16mib" 220

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
