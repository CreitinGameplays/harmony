#!/usr/bin/env bash
# harmony-base parser tests (docs/harmony.md §18, §19.7 M0 round-trip).
#
# Positive cases parse cleanly and (where given) the `--dump-ast` output must
# match a golden AST dump byte for byte. Negative cases must stop with the
# named diagnostic code (a `// WANT:`-style second argument).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Both compilers expose --dump-ast; the v1 driver added it during the
# bootstrap burn-in so this suite runs strictly in both lanes.
PARSE_FLAGS=(--dump-ast check)

ok_case() {
    local name="$1"
    # Parser-only check: --dump-ast skips the type checker on both compilers.
    "$HB" "${PARSE_FLAGS[@]}" "$TMP/c.harmony" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        pass=$((pass + 1)); printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL %s (expected clean parse)\n' "$name"
        "$HB" check "$TMP/c.harmony" 2>&1 | head -4 | sed 's/^/     /'
    fi
}

ast_case() {
    # name; then source on stdin; golden AST text as $2
    local name="$1" want="$2"
    "$HB" --dump-ast check "$TMP/c.harmony" >"$TMP/ast.out" 2>/dev/null
    printf '%s\n' "$want" > "$TMP/ast.want"
    if diff -q "$TMP/ast.want" "$TMP/ast.out" >/dev/null; then
        pass=$((pass + 1)); printf 'ok   %s (ast)\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL %s (ast mismatch)\n' "$name"
        diff "$TMP/ast.want" "$TMP/ast.out" | head -10 | sed 's/^/     /'
    fi
}

reject_case() {
    local name="$1" want="$2"
    out="$("$HB" "${PARSE_FLAGS[@]}" "$TMP/c.harmony" 2>&1)"
    if echo "$out" | grep -q "$want"; then
        pass=$((pass + 1)); printf 'ok   %s (rejected with %s)\n' "$name" "$want"
    else
        fail=$((fail + 1)); printf 'FAIL %s (wanted %s)\n' "$name" "$want"
        echo "$out" | head -3 | sed 's/^/     /'
    fi
}

write() { printf '%b' "$1" > "$TMP/c.harmony"; }

# ---------------------------------------------------------------- items

write 'fn main() {}\n'
ok_case "empty main"

write 'export fn add(a: i32, b: i32) -> i32 { return a + b; }\n'
ok_case "export fn with params and return type"

write 'extern "C" fn abs(x: i32) -> i32;\nextern "C" fn exit(code: i32);\n'
ok_case "extern fn declarations with an ABI"

write 'const MAX: i32 = 8;\nconst GREETING: &life(static) str = "hi";\n'
ok_case "const items incl. life(static)"

write 'copy struct Point { x: i32; y: i32; }\nstruct Player { name: String; pos: Point; }\n'
ok_case "structs, copy marking"

write 'copy enum Shape { Circle(f64), Rect(f64, f64), Dot, }\nenum Maybe { Has(i32), Empty }\n'
ok_case "enums with payloads and trailing comma"

write 'struct Counter { count: u32; }\nmethods Counter {\n    export fn make() -> Counter { return Counter { .count = 0 }; }\n    export fn bump(&mut self) { self.count += 1; }\n    fn get(&self) -> u32 { return self.count; }\n}\n'
ok_case "methods block with self forms"

write 'import "geometry.harmony";\nimport "std/io.harmony";\nfn main() {}\n'
ok_case "imports"

write 'fn pick<T: copy + ord>(a: T, b: T) -> T { return a; }\nfn wrap<life a>(x: &life(a) i32) { return; }\n'
ok_case "generics: type params with bounds, life params"

write 'fn main() { return; }\nfn helper() { return; }\n'
ok_case "multiple items in order"

# ---------------------------------------------------------------- types

write 'fn f(a: &i32, b: &mut i32, c: &life(a) str, d: raw u8, e: raw mut u8, g: [i32; 3], h: &[i32], k: Heap<Box>) { return; }\nfn main() {}\n'
ok_case "type forms: ref/mut/life/raw/array/slice/path+generics"

write 'fn f(m: Vec<Vec<i32>>) { return; }\nfn main() {}\n'
ok_case "nested generic type args"

# ---------------------------------------------------------------- statements

write 'fn main() { let x = 5; let mut y: i32; let _ = 1; if (x > 3) { y = 1; } else { y = 2; } }\n'
ok_case "let/deferred init/_ binding/if-else"

write 'fn main() { let mut n = 3; while (n > 0) { n -= 1; if (n == 1) { break; } continue; } }\n'
ok_case "while with break/continue"

write 'fn main() { let mut t = 0; for (let mut i = 0; i < 10; i += 1) { t += i; } }\n'
ok_case "C-style for"

write 'fn main() { let mut t = 0; for (i : 0..10) { t += 1; } for (i : 0..=10) { t += 1; } }\n'
ok_case "range for heads (.. and ..=)"

write 'fn main() { for (n : items) { return; } }\n'
ok_case "collection for head"

write 'fn main() { let x = 1; switch (x) { case 1: { return; } case 2 | 3: { return; } case 4..=9: { return; } default: { return; } } }\n'
ok_case "switch with or-patterns, range, default"

write 'fn main() { unchecked("i < len was checked above") { return; } }\n'
ok_case "unchecked blocks with reasons"

write 'unchecked("p is valid for n bytes, checked by the caller") fn sum_bytes(p: i64, n: usize) -> i64 { return 0; }\nfn main() {}\n'
ok_case "unchecked fn with a contract string"

write 'fn id<T>(x: T) -> T { return x; }\nfn main() { let a = id(1); let b = id("s"); return; }\n'
ok_case "inferred generic calls (no explicit type args)"

write 'fn main() { { let inner = 1; } return; }\n'
ok_case "bare block statement (scope)"

write 'fn f() -> i32 { return 1; }\nfn main() { let x = f(); f(); return; }\n'
ok_case "call statements and value calls"

# ---------------------------------------------------------------- expressions

write 'fn main() { let a = 1 + 2 * 3 - 4 / 2 % 3; let b = (1 + 2) * 3; }\n'
ok_case "arithmetic precedence and parens"

write 'fn main() { let a = 1 << 2 | 3 & 4 ^ 5; let b = 1 == 2 && 3 != 4 || true; }\n'
ok_case "bitwise/logical precedence"

write 'fn main() { let a = -1; let b = !true; let c = ~0; let d = 1 < 2; let e = 2 >= 1; }\n'
ok_case "unary operators and comparisons"

write 'struct P { x: i32; y: i32; }\nfn main() { let p = P { .x = 1, .y = 2 }; let q = p.x + p.y; let r = &p; let v = *r; }\n'
ok_case "struct init, field access, borrow/deref"

write 'fn main() { let a = arr[0]; let b = m[1][2]; let c = f(1, 2,); let d = x.g<h>(3); }\n'
ok_case "index chains, trailing comma, generic method call"

write 'fn main() { let a = x[1..3]; let b = x[..3]; let c = x[3..]; let d = x[..]; let e = x[1..=3]; }\n'
ok_case "slice range indexes (open/mixed/inclusive)"

write 'fn main() { let a = [1, 2, 3]; let b = [0; 8]; let c = []; let d = sizeof(i32); }\n'
ok_case "array literals (list, repeat, empty), sizeof"

write 'fn main() { let mut b: Heap<i32> = heap(42); *b += 1; }\n'
ok_case "heap(expr) allocation and deref assign"

write 'struct Node { value: i32; next: Maybe<Heap<Node>>; }\nfn push_front(head: Maybe<Heap<Node>>, value: i32) -> Maybe<Heap<Node>> { return Has(heap(Node { .value = value, .next = head })); }\nfn main() { }\n'
ok_case "heap(...) with a struct literal"

write 'enum Tree { Leaf, Branch(Heap<Tree>, i32, Heap<Tree>) }\nfn main() { let t = Tree::Branch(heap(Tree::Leaf), 5, heap(Tree::Leaf)); }\n'
ok_case "heap(...) inside an enum payload"

write 'fn main() { let big = heap([0u8; 8_000_000]); }\n'
ok_case "heap(...) of a large array literal"

write 'fn main() { let x = new 42; }\n'
reject_case "`new` is no longer a keyword (parses as a name)" "SYN-04"

write 'fn main() { let r = 0..10; let s = 0..=10; }\n'
ok_case "range expressions"

write 'fn f(x: i32) -> i32 { return x as i64 as i32; }\nfn main() {}\n'
ok_case "as-cast chain"

# ---------------------------------------------------------------- AST shapes

write 'fn main() { let x = 1 + 2; }\n'
ast_case "binary op tree" 'program
  fn main
    block
      let x
        binary +
          int #1
          int #2'

write 'fn add(a: i32, b: i32) -> i32 { return a + b; }\n'
ast_case "fn with params" 'program
  fn add
    type-name i32
    block
      return
        binary +
          path a
          path b
    param a
      type-name i32
    param b
      type-name i32'

write 'copy struct Point { x: i32; y: i32; }\n'
ast_case "struct decl" 'program
  struct Point #1
    field x
      type-name i32
    field y
      type-name i32'

write 'fn main() { let p = Point { .x = 1 }; }\n'
ast_case "struct init" 'program
  fn main
    block
      let p
        struct-init Point
          field-init x
            int #1'

write 'fn main() { switch (x) { case Has(v): { return; } default: { return; } } }\n'
ast_case "switch arms" 'program
  fn main
    block
      switch
        path x
        arm
          block
            return
          pat-variant Has
            pat-bind v
        arm
          block
            return'

# ---------------------------------------------------------------- negative

write 'fn main() { let x = 1 }\n'
reject_case "missing semicolon before }" "SYN-04"

write 'fn main() { let x = 1 return; }\n'
reject_case "missing semicolon mid-block" "SYN-04"

write 'fn main() { if x > 3 { return; } }\n'
reject_case "unparenthesized condition" "SYN-01"

write 'fn main() { if (x) return; }\n'
reject_case "brace-less body" "SYN-02"

write 'fn main() { let x = 5; if (x = 3) { return; } }\n'
reject_case "assignment as condition" "SYN-03"

write 'fn main() { return; )\n'
reject_case "stray closing paren" "SYN-05"

write 'fn main() { let = 5; }\n'
reject_case "let without a name" "SYN-05"

write 'fn main() { switch (x) { return; } }\n'
reject_case "arm without case/default" "SYN-05"

write 'fn main() { switch (x) { case 1: return; } }\n'
reject_case "arm body without braces" "SYN-02"

write '42\n'
reject_case "junk at top level" "SYN-05"

write 'fn () {}\n'
reject_case "fn without a name" "SYN-05"

write 'fn main( { return; }\n'
reject_case "unclosed parameter list" "SYN-05"

# Recovery: several errors in one file are all reported (§16.1 style).
write 'fn main() { let x = 1; let y = ; let z = 3; }\n'
out="$("$HB" check "$TMP/c.harmony" 2>&1)"
if [ "$(echo "$out" | grep -c STOP)" -ge 1 ] && echo "$out" | grep -q "SYN"; then
    pass=$((pass + 1)); printf 'ok   recovery reports and continues\n'
else
    fail=$((fail + 1)); printf 'FAIL recovery reports and continues\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
