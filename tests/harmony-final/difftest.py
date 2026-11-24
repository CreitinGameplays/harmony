#!/usr/bin/env python3
"""Differential test: the rewrite's lexer vs harmony-base's `--dump-tokens`.

For each source snippet in the corpus, this builds a small Harmony program
with the snippet embedded as a string literal, runs the rewrite's scanner via
harmony-base, and compares its token stream against harmony-base's own
`--dump-tokens` output. Both are normalized to `(kind, text, ival, suffix)`
tuples, so only the token *stream* matters -- not the dump's punctuation.

The scanner must match on every token class: keywords, identifiers, all
literal forms (including escapes and suffixes), punctuation (including the
two- and three-byte operators), comments, and EOF.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import env

ROOT = env.ROOT
HB = env.HB   # oracle: legacy --dump-tokens
HC = env.HC   # compiler under test: runs the scanner driver
DRIVER = os.path.join(ROOT, "tests", "harmony-final", "tokdriver.hr")
TMP = tempfile.mkdtemp(prefix="harmony-tok-")

# Each entry is a source snippet. They are deliberately dense: a single
# snippet covering many classes is faster than one per token, and a mismatch
# still tells us which line to bisect.
SNIPPETS = [
    "fn main() -> i32 { let x = 42; return x; }",
    "const K: usize = 4_000; enum E { A, B(i32) } struct S { f: u8; }",
    "let a = 0xFF; let b = 0o17; let c = 0b1010; let d = 1_000_000;",
    "let a = 1.5; let b = 1e-3; let c = 2.5f32; let d = 1.5E+3;",
    "let a: u8 = 200u8; let b: i64 = 7i64; let c = 9usize;",
    "let s = \"hello\\n\\t\\\"q\\\"\\\\\"; let e = \"\"; let u = \"\\u{1F600}\";",
    "let c = 'A'; let n = '\\n'; let u = '\\u{1F980}'; let b = b'z'; let z = b'\\0';",
    "if (a == b && c != d || e <= f && g >= h) { return 1; }",
    "let mut x = 0; x += 1; x -= 2; x *= 3; x /= 4; x %= 5;",
    "let x = a & b | c ^ d; let y = a << 2; let z = b >> 1;",
    "let t = true; let f = false; let r = &mut x; let s = *r;",
    "// a line comment\n/* a /* nested */ block */\nlet after = 1;",
    "for (i : 0..10) { } let j = 1..=5; let p = a::b; let q = a->b;",
    "match => default case switch while for break continue return",
    "unchecked(\"reason\") { let p = heap(0u8); let s = sizeof(u8); }",
    "raw mut raw u8 as extern import export copy methods self life",
    # Adversarial / edge cases. Each still must match harmony-base exactly.
    "0 1 9 10 99 100 999 1000 1_2_3 0x0 0b1 0o7",
    "3.14 0.0 1. 1e5 1E5 1e+5 1e-5 0.5e2 9.99f32 1e3f64",
    "'\\0' '\\'' '\\\\' b'a' b'\\n' b'\\u{41}'",
    "\"\" \"a\" \"\\0\" \"\\u{1F600}\" \"a\\nb\"",
    "/*one*/ /*two /*three*/ four*/ // tail\nnext",
    "1..2 1..=2 0..0 0..=0 a..b a..=b",
    "a && b && c || d || e !a ~b -c +d *e /f %g",
    "a<b a<=b a>b a>=b a==b a!=b a=b a+=b a-=b a*=b a/=b",
    "a&=b a|=b a^=b a<<=b a>>=b a<<b a>>b",
    "if else while for switch case default return break continue",
    "fn let mut const struct enum methods copy export import extern",
    "true false as sizeof heap unchecked raw self",
    # `abilities` is a v1 keyword in the final compiler only; harmony-base
    # stays v0 and lexes it as an identifier. It is covered by the v1 gate.
    "async await macro try unsafe impl match trait pub use loop goto",
    "null NULL nullptr malloc free new delete Box Option Some None Result Ok Err panic",
    "b'z' b'\\u{41}' 'z' '\\u{1F600}' '\\u{10FFFF}'",
]

# R2 used to be a hand-written corpus. Every v0 codegen fixture is now part of
# the token differential too, so a new fixture cannot silently introduce a
# spelling the two lexers disagree about.
for _path in sorted(glob.glob(os.path.join(
        ROOT, "tests", "harmony", "codegen", "*.harmony"))):
    if os.path.getsize(_path) <= 20000:
        with open(_path) as _f:
            SNIPPETS.append(_f.read())

# The driver template. `%s` is replaced with a Harmony string literal
# containing the snippet.
TEMPLATE = '''import "REL/library/core/fmt.hr";
import "REL/library/core/str.hr";
import "REL/library/core/mem.hr";
import "REL/harmony/lexer/token.hr";
import "REL/harmony/lexer/ctx.hr";
import "REL/harmony/lexer/scan.hr";

fn run(src: &str) -> i32 {
    let mut arena: mem::Arena = mem::Arena { .cur = Raw::null() };
    let mut c: ctx::Ctx = ctx::make(src, "snippet.harmony");
    scan::scan(&mut c, &mut arena);
    let mut i: usize = 0;
    while (i < c.toks.len()) {
        let t = c.toks.get(i);
        println("{}\t{}\t{}\t{}", token::kind_name(t.kind),
                tok_text(t.text), t.ival, t.suffix);
        i += 1;
    }
    return c.diags.len() as i32;
}

// Print the text with non-printable bytes escaped, so a cooked string with a
// newline is one line in the output. Uses the same escapes as harmony-base.
fn tok_text(s: &str) -> &str {
    let mut out: str::String = str::String::make();
    let b = s.as_bytes();
    let mut i: usize = 0;
    while (i < s.len()) {
        let c = b[i];
        if (c == 10u8) { out.push("\\\\n"); }
        else if (c == 13u8) { out.push("\\\\r"); }
        else if (c == 9u8) { out.push("\\\\t"); }
        else if (c == 92u8) { out.push("\\\\\\\\"); }
        else if (c < 32 || c == 127 || c >= 128) {
            out.push("\\\\x");
            out.push_hex(c as u64, 2);
        } else {
            out.push_byte(c);
        }
        i += 1;
    }
    return out.as_str();
}

fn main() -> i32 {
    return run(%s);
}
'''


def hs_escape(s):
    """Escape a Python string as a Harmony string literal body."""
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


def parse_hb(text):
    """Parse harmony-base's --dump-tokens into (kind, text, ival, suffix)."""
    out = []
    for line in text.splitlines():
        m = re.match(r'^(eof|ident|kw|int|float|str|char|byte|punct) (.*)$', line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2)
        ival, suffix = "", ""
        if rest.startswith('"'):
            # A quoted spelling. Find the closing unescaped quote.
            i = 1
            body = ""
            while i < len(rest):
                if rest[i] == "\\" and i + 1 < len(rest):
                    nxt = rest[i + 1]
                    body += {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}.get(nxt, "\\" + nxt)
                    i += 2
                elif rest[i] == '"':
                    i += 1
                    break
                else:
                    body += rest[i]
                    i += 1
            tail = rest[i:].strip()
        elif rest.startswith("'"):
            body = rest[1:-1] if rest.endswith("'") else rest[1:]
            tail = ""
        else:
            body, tail = rest, ""
        vm = re.search(r'=(-?\d+)', tail)
        sm = re.search(r'sfx=(\S+)', tail)
        if vm:
            ival = vm.group(1)
        if sm:
            suffix = sm.group(1)
        out.append((kind, body, ival, suffix))
    return out


def parse_rewrite(text):
    """Parse the rewrite driver's output into the same tuple shape."""
    out = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        kind, body, ival, suffix = parts
        # Decode our driver's escapes the same way parse_hb decodes
        # harmony-base's, so the two text fields are comparable.
        # Single left-to-right pass: decode \n \r \t \\ \", but leave
        # \xNN literal (that is what harmony-base's dump does too).
        _esc = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}
        body = re.sub(r"\\(n|r|t|\\|\")", lambda m: _esc[m.group(1)], body)
        if kind == "eof":
            body, ival, suffix = "<eof>", "", ""
        # harmony-base prints `=ival` only for int/char/byte and `sfx=`
        # only for int/float; our driver prints both for every token.
        if kind not in ("int", "char", "byte"):
            ival = ""
        if kind not in ("int", "float"):
            suffix = ""
        out.append((kind, body, ival, suffix))
    return out


def main():
    failures = 0
    checked = 0
    for idx, src in enumerate(SNIPPETS):
        srcfile = os.path.join(TMP, "s%d.harmony" % idx)
        with open(srcfile, "w") as f:
            f.write(src)
        hb = subprocess.run([HB, "--dump-tokens", srcfile],
                            capture_output=True, text=True)
        if hb.returncode != 0:
            print("FAIL snippet %d: harmony-base rejected it:\n%s" %
                  (idx, hb.stderr[:400]))
            failures += 1
            continue
        drv = os.path.join(TMP, "d%d.harmony" % idx)
        # The driver is generated in a system temp directory, so compute the
        # relative path back to the repo for its imports.
        rel = os.path.relpath(ROOT, TMP)
        tpl = TEMPLATE.replace("REL/", rel + "/")
        tpl = tpl % ('"' + hs_escape(src) + '"',)
        with open(drv, "w") as f:
            f.write(tpl)
        rw = subprocess.run([HC, "run", drv], capture_output=True, text=True)
        if rw.returncode != 0:
            print("FAIL snippet %d: rewrite driver failed:\n%s" %
                  (idx, (rw.stdout + rw.stderr)[:500]))
            failures += 1
            continue
        hbt = parse_hb(hb.stdout)
        rwt = parse_rewrite(rw.stdout)
        checked += 1
        if hbt != rwt:
            print("FAIL snippet %d: %r" % (idx, src[:60]))
            for i, (a, b) in enumerate(zip(hbt, rwt)):
                if a != b:
                    print("  token %d: harmony-base=%r rewrite=%r" % (i, a, b))
                    break
            if len(hbt) != len(rwt):
                print("  length: harmony-base=%d rewrite=%d" %
                      (len(hbt), len(rwt)))
            failures += 1
    print("\n%d snippets checked, %d mismatches" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
