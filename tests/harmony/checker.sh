#!/usr/bin/env bash
# harmony-base type checker tests (docs/harmony.md §5, §6, §7, §8).
#
# Positive cases type-check cleanly (exit 0). Negative cases must stop with
# the named diagnostic code; a `// WANT:` comment selects it. The checker
# runs on `check` (not `--dump-ast`, which skips it).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HB="$ROOT/build/harmony-base"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok_case() {
    local name="$1"
    "$HB" check "$TMP/c.harmony" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        pass=$((pass + 1)); printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL %s (expected a clean check)\n' "$name"
        "$HB" check "$TMP/c.harmony" 2>&1 | head -5 | sed 's/^/     /'
    fi
}

reject_case() {
    local name="$1" want="$2"
    out="$("$HB" check "$TMP/c.harmony" 2>&1)"
    if echo "$out" | grep -q "$want"; then
        pass=$((pass + 1)); printf 'ok   %s (rejected with %s)\n' "$name" "$want"
    else
        fail=$((fail + 1)); printf 'FAIL %s (wanted %s)\n' "$name" "$want"
        echo "$out" | head -4 | sed 's/^/     /'
    fi
}

write() { printf '%b' "$1" > "$TMP/c.harmony"; }

# ---------------------------------------------------------------------------
# Positive: scalars, functions, arithmetic.
# ---------------------------------------------------------------------------
write 'fn add(a: i32, b: i32) -> i32 { return a + b; }\nfn main() -> i32 { return add(1, 2); }\n'
ok_case "function call and arithmetic"

write 'fn main() -> i32 {\n  let x = 5;\n  let y = x * 2 + 1;\n  return y;\n}\n'
ok_case "let inference and precedence"

write 'fn main() {\n  let x = 1;\n}\n'
ok_case "unit-returning main"

write 'fn main() -> i32 {\n  return 0;\n}\n'
ok_case "i32-returning main"

# ---------------------------------------------------------------------------
# Positive: structs, enums, methods.
# ---------------------------------------------------------------------------
write 'struct P { x: i32; y: i32; }\nfn main() -> i32 {\n  let p = P { .x = 1, .y = 2 };\n  return p.x + p.y;\n}\n'
ok_case "struct literal and field access"

write 'copy enum Sh { Circle(f64), Dot, }\nfn main() -> i32 {\n  let s = Sh::Dot;\n  switch (s) { case Circle(r): { return 1; } case Dot: { return 0; } }\n  return 0;\n}\n'
ok_case "enum variant construction and switch"

write 'struct C { n: i32; }\nmethods C {\n  fn make() -> C { return C { .n = 0 }; }\n  fn bump(&mut self) { self.n += 1; }\n  fn get(&self) -> i32 { return self.n; }\n}\nfn main() -> i32 {\n  let mut c = C::make();\n  c.bump();\n  return c.get();\n}\n'
ok_case "methods with self forms"

# ---------------------------------------------------------------------------
# Positive: control flow, arrays, heap, casts.
# ---------------------------------------------------------------------------
write 'fn main() -> i32 {\n  let mut v = [1, 2, 3];\n  v[1] = 9;\n  let mut t = 0;\n  for (let mut i = 0; i < 3; i += 1) { t += v[i]; }\n  while (t > 0) { t -= 1; }\n  return t;\n}\n'
ok_case "arrays, for, while"

write 'fn main() -> i32 {\n  let p = heap(42);\n  return *p;\n}\n'
ok_case "heap allocation and deref"

write 'fn main() -> i32 {\n  let big: i64 = 5;\n  let small = big as i32;\n  return small;\n}\n'
ok_case "explicit lossless-ish cast"

write 'fn main() -> i32 {\n  let n: usize = sizeof(i64);\n  return 0;\n}\n'
ok_case "sizeof yields usize"

# ---------------------------------------------------------------------------
# Positive: generic inference (§18).
# ---------------------------------------------------------------------------
write 'fn id<T>(x: T) -> T { return x; }\nfn main() -> i32 {\n  let a = id(7);\n  return a;\n}\n'
ok_case "inferred generic call pins T = i32"

write 'fn id<T>(x: T) -> T { return x; }\nfn max<T: ord>(a: T, b: T) -> T { if (a < b) { return b; } return a; }\nfn main() -> i32 {\n  return max(id(1), id(2));\n}\n'
ok_case "nested inferred generic calls"

# ---------------------------------------------------------------------------
# Positive: `unchecked fn` with a contract (§13.1).
# ---------------------------------------------------------------------------
write 'unchecked("n is a small literal chosen by the caller")\nfn f(n: i64) -> i64 { return n; }\nfn main() -> i32 {\n  let mut t: i64 = 0;\n  unchecked("n = 1 is a small literal") { t = f(1); }\n  return t as i32;\n}\n'
ok_case "unchecked fn with a contract, called under a promise"

# ---------------------------------------------------------------------------
# Negative: type errors.
# ---------------------------------------------------------------------------
write 'fn main() -> i32 { let x: i32 = "hi"; return 0; }\n'
reject_case "string into i32" "TYPE-01"

write 'fn main() -> i32 {\n  let n = 1;\n  if (n) { return 1; }\n  return 0;\n}\n'
reject_case "non-bool condition" "TYPE-01"

write 'fn main() -> i32 {\n  let a: i32 = 1;\n  let b: i64 = 2;\n  return a + b;\n}\n'
reject_case "mixed-type arithmetic" "TYPE-01"

write 'fn add(a: i32, b: i32) -> i32 { return a + b; }\nfn main() -> i32 { return add(1); }\n'
reject_case "wrong arity" "TYPE-03"

write 'struct P { x: i32; }\nfn main() -> i32 { let p = P { .x = 1 }; return p.y; }\n'
reject_case "unknown field" "TYPE-02"

write 'fn main() -> i32 { return undefined_name; }\n'
reject_case "unknown name" "NAME-01"

write 'struct P { x: i32; }\nfn main() -> i32 { let p = P { .x = 1 }; return 0; }\n'
ok_case "single-field struct"

# ---------------------------------------------------------------------------
# Negative: mutability and initialization.
# ---------------------------------------------------------------------------
write 'fn main() -> i32 { let x = 1; x = 2; return x; }\n'
reject_case "assign to immutable" "MUT-01"

write 'fn main() -> i32 { let x: i32; return x; }\n'
reject_case "use before init" "INIT-01"

# ---------------------------------------------------------------------------
# Negative: switch exhaustiveness.
# ---------------------------------------------------------------------------
write 'enum C { R, G, B, }\nfn main() -> i32 {\n  let c = C::R;\n  switch (c) { case C::R: { return 1; } }\n  return 0;\n}\n'
reject_case "non-exhaustive enum switch" "CASE-01"

write 'fn main() -> i32 {\n  let n = 3;\n  switch (n) { case 1: { return 1; } }\n  return 0;\n}\n'
reject_case "switch on int without default" "CASE-01"

# ---------------------------------------------------------------------------
# Negative: entry point.
# ---------------------------------------------------------------------------
write 'fn main() -> bool { return true; }\n'
reject_case "main returns bool" "TYPE-06"

# ---------------------------------------------------------------------------
# Negative: missing return.
# ---------------------------------------------------------------------------
write 'fn f() -> i32 { let x = 1; }\nfn main() -> i32 { return f(); }\n'
reject_case "missing return" "RET-01"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
