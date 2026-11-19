#!/usr/bin/env python3
"""Differential test: the rewrite's type checker vs harmony-base.

Every program is checked twice: harmony-base's `check --all` and the rewrite's
batched checker driver (one build for the whole corpus). The SET of diagnostic
codes must match exactly for every case.
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typeharness

ROOT = typeharness.ROOT
HB = typeharness.HB
TMP = tempfile.mkdtemp(prefix="hd-type-", dir="/tmp/opencode")

CASES = [
    ("add", "fn add(a: i32, b: i32) -> i32 { return a + b; }\nfn main() -> i32 { return add(1, 2); }\n"),
    ("let-infer", "fn main() -> i32 { let x = 5; let y = x * 2 + 1; return y; }\n"),
    ("unit-main", "fn main() { let x = 1; }\n"),
    ("struct-field", "struct P { x: i32; y: i32; }\nfn main() -> i32 { let p = P { .x = 1, .y = 2 }; return p.x + p.y; }\n"),
    ("enum-switch", "copy enum Sh { Circle(f64), Dot, }\nfn main() -> i32 { let s = Sh::Dot; switch (s) { case Circle(r): { return 1; } case Dot: { return 0; } } return 0; }\n"),
    ("methods", "struct C { n: i32; }\nmethods C { fn make() -> C { return C { .n = 0 }; } fn bump(&mut self) { self.n += 1; } fn get(&self) -> i32 { return self.n; } }\nfn main() -> i32 { let mut c = C::make(); c.bump(); return c.get(); }\n"),
    ("arrays-for", "fn main() -> i32 { let mut v = [1, 2, 3]; v[1] = 9; let mut t = 0; for (let mut i = 0; i < 3; i += 1) { t += v[i]; } while (t > 0) { t -= 1; } return t; }\n"),
    ("heap-deref", "fn main() -> i32 { let p = heap(42); return *p; }\n"),
    ("cast", "fn main() -> i32 { let big: i64 = 5; let small = big as i32; return small; }\n"),
    ("sizeof", "fn main() -> i32 { let n: usize = sizeof(i64); return 0; }\n"),
    ("generic-infer", "fn id<T>(x: T) -> T { return x; }\nfn main() -> i32 { let a = id(7); return a; }\n"),
    ("borrow", "fn main() -> i32 { let x = 5; let r = &x; return *r; }\n"),
    ("mut-borrow", "fn main() -> i32 { let mut x = 5; let r = &mut x; *r = 9; return x; }\n"),
    ("string", "fn main() -> i32 { println(\"hi {}\", 42); return 0; }\n"),
    ("bool-cond", "fn main() -> i32 { if (true) { return 1; } return 0; }\n"),
    ("raw-null", "fn main() -> i32 { let p: raw mut u8 = Raw::null(); return 0; }\n"),
    ("unknown-fn", "fn main() -> i32 { return missing_fn(); }\n"),
    ("type-mismatch", "fn main() -> i32 { let x: i32 = true; return 0; }\n"),
    ("condition", "fn main() -> i32 { if (5) { return 1; } return 0; }\n"),
    ("arity", "fn f(a: i32) -> i32 { return a; }\nfn main() -> i32 { return f(1, 2); }\n"),
    ("no-field", "struct P { x: i32; }\nfn main() -> i32 { let p = P { .x = 1 }; return p.y; }\n"),
    ("missing-return", "fn f() -> i32 { let x = 1; }\nfn main() -> i32 { return 0; }\n"),
    ("arith-bool", "fn main() -> i32 { let x = true + false; return 0; }\n"),
    ("bad-main", "fn main(a: i32) -> i32 { return a; }\n"),
    ("uninit", "fn main() -> i32 { let x: i32; return x; }\n"),
    ("mut-err", "fn main() -> i32 { let x = 1; x = 2; return x; }\n"),
    ("fmt-count", "fn main() -> i32 { println(\"{} {}\", 1); return 0; }\n"),
    ("fmt-literal", "fn main() -> i32 { let s = \"x\"; println(s, 1); return 0; }\n"),
    ("unchecked-weak", "fn main() -> i32 { unchecked(\"short\") { let x = 1; } return 0; }\n"),
    ("extern-call", "extern \"C\" fn puts(s: &str) -> i32;\nfn main() -> i32 { return puts(\"hi\"); }\n"),
    ("index-str", "fn main() -> i32 { let s = \"abc\"; return s[0] as i32; }\n"),
    ("deref-int", "fn main() -> i32 { let x = 5; return *x; }\n"),
]


def hb_codes(src):
    d = tempfile.mkdtemp(prefix="hc-", dir=TMP)
    f = os.path.join(d, "main.harmony")
    open(f, "w").write(src)
    for m in re.findall(r'import "([^"]+)"', src):
        t = os.path.join(d, m)
        os.makedirs(os.path.dirname(t), exist_ok=True)
        open(t, "w").write(open(os.path.join(ROOT, m)).read())
    r = subprocess.run([HB, "check", "--all", f], capture_output=True, text=True)
    return set(re.findall(r"\b([A-Z]+-\d+)\b", r.stdout + r.stderr))


def main():
    rw = dict(typeharness.run_cases([(n, s) for n, s in CASES]))
    fail = 0
    for name, src in CASES:
        hb = hb_codes(src)
        got = rw.get(name, set())
        if hb != got:
            print("%-45s hb=%-24s rw=%s" % (name, sorted(hb), sorted(got)))
            fail += 1
    print("\n%d cases, %d mismatches" % (len(CASES), fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
