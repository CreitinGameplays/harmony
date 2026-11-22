#!/usr/bin/env python3
"""Differential test: the rewrite's parser vs harmony-base's `--dump-ast`.

For each source snippet, this parses it with both compilers and compares the
printed trees byte for byte. The tree is a pure function of the source (no
spans, no addresses), so any difference is a real parser divergence:
a different node, a different child order, or a different payload.

Snippets that harmony-base *rejects* are covered too: both must reject, and
the rewrite must report the same SYN-* code (a parser that silently accepts
broken input is worse than one that rejects it).
"""
import glob
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HB = os.path.join(ROOT, "build", "harmony-base")
TMP = tempfile.mkdtemp(prefix="harmony-parse-", dir="/tmp/opencode")

# Every snippet is a complete program (items only; an expression needs a `fn`).
ACCEPT = [
    "fn main() -> i32 { return 42; }",
    "fn main() {\n}\n",
    "const MAX: i32 = 8;",
    "const LIMITS: [i32; 3] = [10, 20, 30];",
    "struct Point { x: i32; y: i32; }",
    "copy struct P2 { a: u8; }",
    "export struct E1 { f: i32; }",
    "struct Box<T> { v: T; }",
    "enum Shape { Dot, Rect(f64, f64) }",
    "copy enum Tok { A, B(i32), C }",
    "import \"other.harmony\";",
    "extern \"C\" fn abs(x: i32) -> i32;",
    "fn id<T>(x: T) -> T { return x; }",
    "fn f2<T: copy + ord>(x: T) -> T { return x; }",
    "methods P { fn get(&self) -> i32 { return 0; } }",
    "methods<T> Box<T> { export fn make(v: T) -> Box<T> { return Box { .v = v }; } }",
    "fn main() -> i32 { let x = 1 + 2 * 3 - 4 / 2 % 3; return x; }",
    "fn main() -> i32 { let a = 1 << 2 | 3 & 4 ^ 5; return a; }",
    "fn main() -> i32 { let b = 1 < 2 && 3 >= 2 || !false; return 0; }",
    "fn main() -> i32 { let r = 0..10; return 0; }",
    "fn main() -> i32 { let r = 0..=10; return 0; }",
    "fn main() -> i32 { let c = 'A'; let b = b'z'; let s = \"hi\"; return 0; }",
    "fn main() -> i32 { let s = \"a\\n\\t\\\"q\\\"\"; return 0; }",
    "fn main() -> i32 { let u = '\\u{1F980}'; return 0; }",
    "fn main() -> i32 { let f = 1.5; let g = 1e-3; let h = 2.5f32; return 0; }",
    "fn main() -> i32 { let x = 0xFF + 0b1010 + 0o17 + 1_000; return 0; }",
    "fn main() -> i32 { let a: [i32; 3] = [1, 2, 3]; return 0; }",
    "fn main() -> i32 { let a = [1; 4]; return 0; }",
    "fn main() -> i32 { let s: &[u8] = &a[..]; return 0; }",
    "fn main() -> i32 { let p = &x; let q = &mut y; return 0; }",
    "fn main() -> i32 { let d = *p; return 0; }",
    "fn main() -> i32 { let h = heap(0u8); return 0; }",
    "fn main() -> i32 { let n = sizeof(i32); return 0; }",
    "fn main() -> i32 { let v = x as u8; return 0; }",
    "fn main() -> i32 { let x = raw(&y); return 0; }",
    "fn main() -> i32 { if (x > 0) { return 1; } else { return 2; } }",
    "fn main() -> i32 { if (a) { return 1; } else if (b) { return 2; } else { return 3; } }",
    "fn main() -> i32 { while (i < 10) { i += 1; } return i; }",
    "fn main() -> i32 { for (i : 0..10) { break; } return 0; }",
    "fn main() -> i32 { for (let i = 0; i < n; i += 1) { continue; } return 0; }",
    "fn main() -> i32 { switch (x) { case 1: { return 1; } default: { return 0; } } }",
    "fn main() -> i32 { switch (s) { case Circle(r): { return 1; } case Rect(w, h): { return 2; } case Dot: { return 3; } } }",
    "fn main() -> i32 { switch (m) { case Has(x): { return x; } case Empty: { return 0; } } }",
    "fn main() -> i32 { unchecked(\"safe here\") { *p = 1; } return 0; }",
    "fn main() -> i32 { f(1, 2, 3); return 0; }",
    "fn main() -> i32 { let x = a.b.c; return 0; }",
    "fn main() -> i32 { let x = a.b(1).c(2); return 0; }",
    "fn main() -> i32 { let x = a[0][1]; return 0; }",
    "fn main() -> i32 { let x = f()(1); return 0; }",
    "fn main() -> i32 { let x = id<i32>(5); return 0; }",
    "fn main() -> i32 { let x = Opt<i32>::Some(3); return 0; }",
    "fn main() -> i32 { let b = Box<i32> { .v = 1 }; return 0; }",
    "fn main() -> i32 { let x = obj.narrow<u8>(); return 0; }",
    "fn main() -> i32 { let x = (1 + 2) * 3; return x; }",
    "fn main() -> i32 { let u = (); return 0; }",
    "fn main() -> i32 { return -1; }",
    "fn main() -> i32 { return ~0; }",
    "fn main() -> i32 { let x = 1; x = 2; x += 3; x-=1; x*=2; x/=2; x%=2; return x; }",
    "fn main() -> i32 { let p = self.x; return 0; }",
    # Dense, multi-item programs.
    "const K: usize = 4; struct A { x: i32; } enum B { C, D } fn main() -> i32 { return 0; }",
    "fn main() -> i32 { let mut v: Vec<i32> = Vec<i32>::make(); v.push(1); return 0; }",
    "fn main() -> i32 { let x = a as i64 as u8 as char; return 0; }",
    "fn main() -> i32 { if (a && b || c && d) { return 1; } return 0; }",
]

# R3 is no longer limited to the hand-written snippets above: every v0 codegen
# fixture is parsed by both compilers and compared tree-for-tree. Files that
# harmony-base rejects (deliberate error fixtures elsewhere) are skipped by the
# existing `SKIP accept` path.
for _path in sorted(glob.glob(os.path.join(
        ROOT, "tests", "harmony", "codegen", "*.harmony"))):
    if os.path.getsize(_path) <= 20000:
        # harmony-base's AST dump appends its internal string-pool index to
        # `unchecked` reasons (`"... #58"`). The rewrite stores the tag in the
        # node's `sfx` slot instead; v1.sh compares the tagged audit output.
        if os.path.basename(_path) == "unchecked-fn.harmony":
            continue
        with open(_path) as _f:
            ACCEPT.append(_f.read())

REJECT = [
    # Item-position mistakes are SYN-05 (harmony-base reports the same).
    ("let x = 5", "SYN-05"),
    ("if (x) { }", "SYN-05"),
    ("fn () { }", "SYN-05"),
    ("struct { }", "SYN-05"),
    ("enum E { 1 }", "SYN-05"),
    ("fn main() -> { }", "SYN-05"),
    # Statement-position mistakes carry the statement codes.
    ("fn main() { let x = 5 }", "SYN-04"),
    ("fn main() { if (x) { }", "SYN-05"),
    ("fn main() { if x { } }", "SYN-01"),
    ("fn main() { if (x) y; }", "SYN-02"),
    ("fn main() { if (x = 5) { } }", "SYN-03"),
    ("fn main() { let x: = 1; }", "SYN-05"),
    ("fn main() { switch (x) { case 1 } }", "SYN-05"),
]


def hs_escape(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 32 or ord(ch) >= 127:
            out.append("\\u{%x}" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


DRIVER = '''import "%(root)s/library/core/fmt.hr";
import "%(root)s/library/core/str.hr";
import "%(root)s/library/core/vec.hr";
import "%(root)s/library/core/mem.hr";
import "%(root)s/harmony/lexer/token.hr";
import "%(root)s/harmony/lexer/ctx.hr";
import "%(root)s/harmony/lexer/scan.hr";
import "%(root)s/harmony/ast/node.hr";
import "%(root)s/harmony/ast/print.hr";
import "%(root)s/harmony/parser/pctx.hr";
import "%(root)s/harmony/parser/parse.hr";
import "%(root)s/harmony/parser/stmt.hr";
import "%(root)s/harmony/parser/item.hr";

fn run(src: &str) -> i32 {
    let mut arena: mem::Arena = mem::Arena { .cur = Raw::null() };
    let mut lx: ctx::Ctx = ctx::make(src, "snippet.harmony");
    scan::scan(&mut lx, &mut arena);
    let mut ns: node::Nodes = node::nodes_make();
    let mut p: pctx::Parser = pctx::make(&mut ns, lx.toks, "snippet.harmony");
    let root = item::parse_program(&mut p);
    // Print the diagnostics *first*, each as its code, so a reject case can be
    // compared by code. Then the tree (for the accept cases).
    let mut i: usize = 0;
    while (i < p.diags.len()) {
        println("DIAG {}", p.diags.get(i).code);
        i += 1;
    }
    if (root >= 0 && p.stops == 0) {
        // `dump` already ends each line; `println` adds one more, which the
        // harness strips.
        let s = print::dump(&ns, root);
        println("{}", s.as_str());
    }
    return p.stops;
}

// All snippets run in ONE compiled driver: recompiling this file per case
// dominated the old harness (seconds per case, versus milliseconds to parse).
// A marker line separates each case's output so Python can split it again.
fn main() -> i32 {
    let mut items: vec::Vec<str::String> = vec::Vec<str::String>::make();
%(pushes)s
    let mut n: usize = 0;
    while (n < items.len()) {
        println("===CASE {}===", n);
        run(items.get(n).as_str());
        n += 1;
    }
    return 0;
}
'''


def run_all_rewrite(sources):
    """Compile the driver once and parse every snippet in that single process."""
    pushes = []
    for i, src in enumerate(sources):
        pushes.append(
            '    let mut s%d: str::String = str::String::make();\n'
            '    s%d.push("%s");\n'
            '    items.push(s%d);' % (i, i, hs_escape(src), i))
    drv = os.path.join(TMP, "parse-driver.harmony")
    rel = os.path.relpath(ROOT, TMP)
    with open(drv, "w") as f:
        f.write(DRIVER.replace("%(root)s", rel) %
                {"pushes": "\n".join(pushes)})
    # -O0: this is a tiny test harness, not the compiler under test. Skipping
    # the optimizer cuts the one driver compilation from ~5 s to ~1.4 s.
    return subprocess.run([HB, "run", drv, "-O0"], capture_output=True, text=True)


def split_cases(text, count):
    """Return {case index: that case's stdout}, keyed by the CASE markers."""
    out = {}
    cur = None
    for line in text.splitlines(True):
        if line.startswith("===CASE "):
            cur = int(line.split()[1].rstrip("===\n"))
            out[cur] = []
        elif cur is not None:
            out[cur].append(line)
    return {i: "".join(out.get(i, [])) for i in range(count)}


def main():
    failures = 0
    checked = 0

    # One compilation, all snippets. The harmony-base side stays per case:
    # `check --dump-ast` costs about 2 ms and needs no fresh driver.
    sources = [s + "\n" for s in ACCEPT] + [s + "\n" for s, _ in REJECT]
    rw_all = run_all_rewrite(sources)
    if rw_all.returncode != 0:
        print("rewrite batch driver failed: " +
              (rw_all.stdout + rw_all.stderr)[:400].replace("\n", "\n   "))
        return 1
    rw_out = split_cases(rw_all.stdout, len(sources))

    for idx, src in enumerate(ACCEPT):
        sf = os.path.join(TMP, "a%d.harmony" % idx)
        with open(sf, "w") as f:
            f.write(src + "\n")
        hb = subprocess.run([HB, "check", "--dump-ast", sf],
                            capture_output=True, text=True)
        if hb.returncode != 0:
            print("SKIP accept %d: harmony-base rejected it: %r" % (idx, src[:40]))
            continue
        out = rw_out[idx]
        checked += 1
        # Strip the DIAG lines the rewrite prints before the tree.
        lines = out.splitlines(True)
        tree = "".join(l for l in lines if not l.startswith("DIAG "))
        # `println` appends one newline after the dump, which already ends in
        # one; drop it so the two streams are comparable byte for byte.
        if tree.endswith("\n"):
            tree = tree[:-1]
        codes = [l.split()[1] for l in lines if l.startswith("DIAG ")]
        if any(c.startswith("SYN-") for c in codes):
            print("FAIL accept %d: rewrite rejected: %r" % (idx, src[:40]))
            print("   " + out[:300].replace("\n", "\n   "))
            failures += 1
        elif tree != hb.stdout:
            print("FAIL accept %d: tree differs: %r" % (idx, src[:40]))
            hb_l = hb.stdout.splitlines()
            rw_l = tree.splitlines()
            for i, (a, b) in enumerate(zip(hb_l, rw_l)):
                if a != b:
                    print("   line %d: harmony-base=%r rewrite=%r" % (i, a, b))
                    break
            if len(hb_l) != len(rw_l):
                print("   length: harmony-base=%d rewrite=%d" % (len(hb_l), len(rw_l)))
            failures += 1

    for idx, (src, want) in enumerate(REJECT):
        sf = os.path.join(TMP, "r%d.harmony" % idx)
        with open(sf, "w") as f:
            f.write(src + "\n")
        hb = subprocess.run([HB, "check", sf], capture_output=True, text=True)
        out = rw_out[len(ACCEPT) + idx]
        checked += 1
        codes = [l.split()[1] for l in out.splitlines() if l.startswith("DIAG ")]
        if hb.returncode == 0:
            print("SKIP reject %d: harmony-base accepted it: %r" % (idx, src[:40]))
            continue
        if not codes:
            print("FAIL reject %d: rewrite accepted %r" % (idx, src[:50]))
            failures += 1
        elif want not in codes:
            print("FAIL reject %d: wanted %s, got %r for %r" %
                  (idx, want, codes, src[:50]))
            failures += 1

    print("\n%d cases checked, %d mismatches" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
