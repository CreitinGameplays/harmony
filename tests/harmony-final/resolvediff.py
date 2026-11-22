#!/usr/bin/env python3
"""Differential test: the rewrite's module loader + resolver vs harmony-base.

Each case is a set of modules (path -> source) plus a root path. The harness
writes the modules to temp files and runs harmony-base `check`, then feeds the
same sources to the rewrite's embedded-source driver. Both must report the
same NAME-* codes (a module that resolves differently would give the checker
and backend different programs).

Cases cover:
  - a module using its own types as generic args (bare-path renaming);
  - transitive imports, diamond imports (merge once), relative paths with
    `.`/`..` normalization;
  - a missing module and a direct/indirect import cycle (NAME-04);
  - duplicate top-level names after merging (NAME-03);
  - unknown names/types (NAME-01).
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HB = os.path.join(ROOT, "build", "harmony-base")
TMP = tempfile.mkdtemp(prefix="harmony-resolve-")

# (name, modules dict path->source, root path)
CASES = [
    ("single", {
        "main.harmony": "fn main() -> i32 { return 0; }",
    }, "main.harmony"),

    ("unknown-fn", {
        "main.harmony": "fn main() -> i32 { return missing(); }",
    }, "main.harmony"),

    ("unknown-type", {
        "main.harmony": "fn main() -> i32 { let x: Missing = 1; return 0; }",
    }, "main.harmony"),

    ("unknown-local", {
        "main.harmony": "fn main() -> i32 { return undefined_var; }",
    }, "main.harmony"),

    ("dup-local", {
        "main.harmony": "fn main() -> i32 { let x = 1; let x = 2; return x; }",
    }, "main.harmony"),

    ("dup-top", {
        "main.harmony": "fn f() -> i32 { return 0; }\nfn f() -> i32 { return 1; }\nfn main() -> i32 { return 0; }",
    }, "main.harmony"),

    ("shadow-ok", {
        "main.harmony": "fn main() -> i32 { let x = 1; { let x = 2; } return x; }",
    }, "main.harmony"),

    ("one-import", {
        "main.harmony": 'import "lib.harmony";\nfn main() -> i32 { return lib::value(); }',
        "lib.harmony": "export fn value() -> i32 { return 7; }",
    }, "main.harmony"),

    ("transitive", {
        "main.harmony": 'import "a.harmony";\nfn main() -> i32 { return a::value(); }',
        "a.harmony": 'import "b.harmony";\nexport fn value() -> i32 { return b::value(); }',
        "b.harmony": "export fn value() -> i32 { return 9; }",
    }, "main.harmony"),

    ("diamond", {
        "main.harmony": 'import "a.harmony";\nimport "b.harmony";\nfn main() -> i32 { return a::value() + b::other(); }',
        "a.harmony": 'import "shared.harmony";\nexport fn value() -> i32 { return shared::value(); }',
        "b.harmony": 'import "shared.harmony";\nexport fn other() -> i32 { return 3; }',
        "shared.harmony": "export fn value() -> i32 { return 4; }",
    }, "main.harmony"),

    ("relative-dot", {
        "main.harmony": 'import "nested/../lib.harmony";\nfn main() -> i32 { return lib::value(); }',
        "lib.harmony": "export fn value() -> i32 { return 5; }",
        "nested/x.harmony": "export fn unused() -> i32 { return 0; }",
    }, "main.harmony"),

    ("self-generic", {
        "main.harmony": 'import "box.harmony";\nfn main() -> i32 { return 0; }',
        "box.harmony": 'export struct Item { n: i32; }\nexport fn make() -> Item { return Item { .n = 7 }; }',
    }, "main.harmony"),

    ("missing-module", {
        "main.harmony": 'import "no-such.harmony";\nfn main() -> i32 { return 0; }',
    }, "main.harmony"),

    ("cycle-direct", {
        "main.harmony": 'import "a.harmony";\nfn main() -> i32 { return 0; }',
        "a.harmony": 'import "main.harmony";\nexport fn f() -> i32 { return 0; }',
    }, "main.harmony"),

    ("cycle-indirect", {
        "main.harmony": 'import "a.harmony";\nfn main() -> i32 { return 0; }',
        "a.harmony": 'import "b.harmony";\nexport fn f() -> i32 { return 0; }',
        "b.harmony": 'import "a.harmony";\nexport fn g() -> i32 { return 0; }',
    }, "main.harmony"),

    ("import-dup", {
        "main.harmony": 'import "a.harmony";\nimport "a.harmony";\nfn main() -> i32 { return 0; }',
        "a.harmony": "export fn f() -> i32 { return 0; }",
    }, "main.harmony"),

    ("use-method", {
        "main.harmony": 'import "counter.harmony";\nfn main() -> i32 { return counter::make().get(); }',
        "counter.harmony": 'export struct Counter { n: i32; }\nmethods Counter { export fn get(&self) -> i32 { return self.n; } export fn make() -> Counter { return Counter { .n = 0 }; } }',
    }, "main.harmony"),

    ("module-enum", {
        "main.harmony": 'import "shapes.harmony";\nfn main() -> i32 { switch (shapes::make()) { case Dot: { return 0; } case Line: { return 1; } } }',
        "shapes.harmony": 'export enum Shape { Dot, Line }\nexport fn make() -> Shape { return Shape::Dot; }',
    }, "main.harmony"),

    ("nested-import", {
        "main.harmony": 'import "a.harmony";\nfn main() -> i32 { return a::f(); }',
        "a.harmony": 'import "b.harmony";\nexport fn f() -> i32 { return b::g(); }',
        "b.harmony": "export fn g() -> i32 { return 11; }",
    }, "main.harmony"),
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


DRIVER = '''import "%(root)s/library/core/vec.hr";
import "%(root)s/library/core/mem.hr";
import "%(root)s/harmony/ast/node.hr";
import "%(root)s/harmony/driver/loader.hr";
import "%(root)s/harmony/sema/resolve.hr";

fn run(mods: &vec::Vec<loader::Module>, root: &str) -> i32 {
    let mut arena: mem::Arena = mem::Arena { .cur = Raw::null() };
    let mut ns: node::Nodes = node::nodes_make();
    let l = loader::load(&mut ns, &mut arena, mods, root);
    let mut r = resolve::make(root);
    if (l.program >= 0) { resolve::resolve(&mut r, &ns, l.program); }
    let mut i: usize = 0;
    while (i < l.diags.len()) { println("DIAG {}", l.diags.get(i).code); i += 1; }
    i = 0;
    while (i < r.diags.len()) { println("DIAG {}", r.diags.get(i).code); i += 1; }
    return 0;
}

// One compiled driver runs every case. Recompiling this file per case used to
// dominate the harness; the loader/resolver themselves take microseconds.
// A marker line separates each case's diagnostics for the Python harness.
fn main() -> i32 {
%(cases)s
    return 0;
}
'''


def codes_from(text):
    return sorted(set(re.findall(r"\b(NAME-\d+|TYPE-\d+|SYN-\d+)\b", text)))


def run_all_rewrite(cases):
    """Compile the driver once and resolve every module set in that process."""
    chunks = []
    for idx, (name, modules, root) in enumerate(cases):
        lines = ['    println("===CASE {}===", %d);' % idx,
                 '    let mut mods%d: vec::Vec<loader::Module> = '
                 'vec::Vec<loader::Module>::make();' % idx]
        for path, src in modules.items():
            lines.append(
                '    mods%d.push(loader::Module { .path = "%s", .src = "%s" });'
                % (idx, hs_escape(path), hs_escape(src)))
        lines.append('    run(&mods%d, "%s");' % (idx, hs_escape(root)))
        chunks.append("\n".join(lines))
    drv = os.path.join(TMP, "resolve-driver.harmony")
    rel = os.path.relpath(ROOT, TMP)
    with open(drv, "w") as f:
        f.write(DRIVER.replace("%(root)s", rel) %
                {"cases": "\n".join(chunks)})
    # -O0: this is a tiny test harness, not the compiler under test. Skipping
    # the optimizer cuts the one driver compilation from ~6 s to ~1 s.
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

    # The rewrite side runs in one driver; the harmony-base side stays per
    # case (`check` needs no compilation and costs about 2 ms).
    rw_all = run_all_rewrite(CASES)
    if rw_all.returncode != 0:
        print("rewrite batch driver failed: " +
              (rw_all.stdout + rw_all.stderr)[:400].replace("\n", "\n   "))
        return 1
    rw_out = split_cases(rw_all.stdout, len(CASES))

    for idx, (name, modules, root) in enumerate(CASES):
        case_dir = os.path.join(TMP, "c%d" % idx)
        os.makedirs(case_dir, exist_ok=True)
        for path, src in modules.items():
            fp = os.path.join(case_dir, path)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "w") as f:
                f.write(src)
        hb = subprocess.run([HB, "check", "--format=line",
                             os.path.join(case_dir, root)],
                            capture_output=True, text=True)
        hb_codes = codes_from(hb.stdout + hb.stderr)

        out = rw_out[idx]
        rw_codes = sorted(set(re.findall(r"DIAG (\w+-\d+)", out)))
        checked += 1
        # The rewrite's resolver checks names only; harmony-base's `check`
        # also reports TYPE-* from later stages. Compare NAME-* codes only.
        hb_names = [c for c in hb_codes if c.startswith("NAME-")]
        if hb_names != rw_codes:
            print("FAIL %s: harmony-base NAME=%r rewrite=%r" %
                  (name, hb_names, rw_codes))
            print("   hb: " + (hb.stdout + hb.stderr)[:240].replace("\n", "\n   "))
            failures += 1
    print("\n%d cases checked, %d mismatches" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
