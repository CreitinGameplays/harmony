#!/usr/bin/env python3
"""harmony-base aggressive fuzzer — the rewrite gate.

Design (docs: tests/fuzz2/README.md). The compiler must be provably stable on
*arbitrary* input before the `harmony` rewrite starts from it, so this tool
combines five engines, each catching what the others miss:

  gen        The grammar sampler. Emits structurally plausible programs from a
             weighted recursive grammar (every language surface: items, types,
             expressions, generics, `unchecked`, `Maybe`/`Outcome`, ...) plus
             adversarial specials (deep nesting near the parser limit, wide
             literals, boundary integers, truncated/over-long tokens). A
             generated program is checked against five oracles; any violation
             is shrunk to a minimal repro. This is the main engine: it reaches
             deep semantic states that byte-flip mutators never see.

  mut        Token-level mutation. Takes the corpus (the real test suite) or
             gen output and applies structure-aware mutations: token splice,
             duplicate/delete/duplicate spans, insert adversarial tokens
             (`>>`, `::`, `{`, deep parens), swap identifiers, split `>>`.
             Runs on any we find, since it walks real syntax farther than
             byte flips.

  afl        AFL++ (dumb mode: the FASM-built binary cannot be instrumented,
             QEMU/FRIDA are absent in this environment). Still valuable: it
             beats the channel hard and its havoc stage can find corrupted
             paths the grammar will never emit (e.g., patching bytes inside
             string cooking). Runs on a curated corpus for a fixed time budget
             or exec count, then replays any findings through the oracles.

  valgrind   A sample of the corpus through memcheck — the only oracle for
             the uninitialised-read class (this build showed them in the
             probing phase). Slower, so it samples.

Oracles (a crash alone is a weak target for a compiler):
  O1  liveness:    exit code is defined and within the driver range
                   (0 ok, 1 stop, 2 usage) and runs terminate under a
                   timeout. A signal death is distinct from a large exit
                   value: `run` forwards `main` mod 256, so 241 is legal.
  O2  agreement:   `check` rc==0  =>  `emit-llvm` rc==0 and non-empty output;
                   `check` rc!=0  =>  `emit-llvm` also refuses (no silent IR
                   for a broken program).
  O3  determinism:emit-llvm twice => byte-identical output.
  O4  optlevel:    for generated programs that *run* and contain no
                   `unchecked` (so behavior is fully defined, §13.6), the exit
                   value agrees across -O0 / -O2 / -O3 (miscompiles surface
                   here).
  O5  mem:         (valgrind only) no uninitialised/invalid accesses.

Findings are shrunk to a minimal reproducer (delta debugging over token
spans), then written under findings/ with the failing oracle named, ready to
become a regression test.
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

try:
    import multiprocessing as mp
    HAVE_MP = True
except ImportError:      # pragma: no cover
    HAVE_MP = False

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HB = os.path.join(ROOT, "build", "harmony-base")
CORPUS_DIRS = [
    os.path.join(ROOT, "tests", "harmony"),
]

TIMEOUT_COMPILER = 60     # seconds; generous (a 33k-line program needs ~5s)
TIMEOUT_RUN = 10
RECV_OK = {0, 1, 2}


# --------------------------------------------------------------------------
# The grammar sampler.
# --------------------------------------------------------------------------

class Gen:
    """Weighted recursive sampler over the harmony grammar (§18).

    Every production is a method returning a string; `_r()` picks one at
    random, weighted so programs stay small but may spike in any dimension
    (depth, width, weird literals). A `spec` string forces one adversarial
    shape and is what the "specials" list builds on.
    """

    def __init__(self, rng):
        self.rng = rng
        # Depth budget: recursion burns it so a single program cannot blow
        # past the parser's own limit (that path is tested explicitly by the
        # deep-nest special, not blindly).
        self.budget = 30

    # ---- entry ----
    def program(self):
        items = []
        n = self.rng.randint(1, 8)
        for _ in range(n):
            items.append(self.item())
        # `main` last so the program is sometimes runnable.
        if self.rng.random() < 0.7:
            items.append("fn main() -> i32 { return %s; }" % self.expr())
        return "\n".join(items) + "\n"

    def item(self):
        r = self.rng
        pick = r.random()
        if pick < 0.30:
            return self.fn()
        if pick < 0.50:
            return self.struct()
        if pick < 0.62:
            return self.enum_()
        if pick < 0.72:
            return self.const_()
        if pick < 0.80:
            return self.methods()
        if pick < 0.86:
            return self.extern_()
        return self.fn()   # more functions

    def fn(self):
        r = self.rng
        name = "f%d" % r.randint(0, 999)
        if r.random() < 0.15:
            params = "<T>"
        else:
            params = ""
        args = []
        for i in range(r.randint(0, 3)):
            t = r.choice(["i32", "i64", "u8", "bool", "f64", "&str",
                          "raw u8", "Maybe<i32>"])
            args.append("x%d: %s" % (i, t))
        ret = r.choice(["i32", "i32", "i64", "u8", "bool", "()", "Maybe<i32>"])
        body = []
        for _ in range(r.randint(1, 6)):
            body.append(self.stmt())
        body.append("return %s;" % self.expr())
        return "fn %s%s(%s) -> %s {\n%s\n}" % (
            name, params, ", ".join(args), ret, "\n".join(body))

    def struct(self):
        r = self.rng
        name = "S%d" % r.randint(0, 999)
        gen = "<T>" if r.random() < 0.3 else ""
        fields = []
        for i in range(r.randint(0, 4)):
            fields.append("f%d: %s;" % (i, self.typestr()))
        return "struct %s%s { %s }" % (name, gen, " ".join(fields))

    def enum_(self):
        r = self.rng
        name = "E%d" % r.randint(0, 999)
        gen = "<T>" if r.random() < 0.25 else ""
        vs = []
        for i in range(r.randint(1, 4)):
            if r.random() < 0.4:
                vs.append("V%d(%s)" % (i, self.typestr()))
            else:
                vs.append("V%d" % i)
        return "enum %s%s { %s }" % (name, gen, ", ".join(vs))

    def const_(self):
        r = self.rng
        name = "C%d" % r.randint(0, 999)
        return "const %s: i32 = %d;" % (name, r.randint(-2**31, 2**31 - 1))

    def methods(self):
        return ("methods M0 {\n"
                "  export fn m(&self) -> i32 { return 0; }\n"
                "}")

    def extern_(self):
        return 'extern "C" fn e() -> i32;'

    # ---- types ----
    def typestr(self):
        r = self.rng
        self.budget -= 1
        if self.budget < 0:
            return "i32"
        pick = r.random()
        if pick < 0.35:
            return "i32"
        if pick < 0.45:
            return "T"
        if pick < 0.55:
            return "&" * r.randint(1, 2) + " " * 0 + self.typestr()
        if pick < 0.65:
            return "[%s; %d]" % (self.typestr(), r.randint(0, 100))
        if pick < 0.72:
            return "&[%s]" % self.typestr()
        if pick < 0.80:
            return "Heap<%s>" % self.typestr()
        if pick < 0.88:
            return "Maybe<%s>" % self.typestr()
        return self.typestr()

    # ---- statements ----
    def stmt(self):
        r = self.rng
        self.budget -= 1
        if self.budget < 0:
            return "let x = 0;"
        pick = r.random()
        if pick < 0.25:
            return "let %s%s = %s;" % (
                "mut " if r.random() < 0.5 else "",
                "v%d" % r.randint(0, 99), self.expr())
        if pick < 0.35:
            return "let mut v%d: %s = %s;" % (
                r.randint(0, 99), self.typestr(), self.zero_of())
        if pick < 0.45:
            return "if (%s) { %s }" % (self.expr(), self.stmt())
        if pick < 0.52:
            return "while (%s) { break; }" % self.boolexpr()
        if pick < 0.60:
            lo = r.randint(-10, 10)
            hi = lo + r.randint(0, 10)
            rng_kind = r.choice(["..", "..="])
            return "for (i : %d%s%d) { %s }" % (lo, rng_kind, hi, self.stmt())
        if pick < 0.68:
            return "switch (%s) { case Has(v): { %s } default: { } }" % (
                "Has(%s)" % self.expr(), self.stmt())
        if pick < 0.74:
            return ('unchecked("long enough reason") { %s }' % self.unchecked_body())
        if pick < 0.80:
            return "{ %s }" % self.stmt()
        return "%s;" % self.expr()

    def zero_of(self):
        return self.rng.choice(["0", "0u8", "false", "Empty", "0.0", '""'])

    def unchecked_body(self):
        r = self.rng
        return r.choice([
            "let mut p: raw mut i32 = alloc<i32>(%d);" % r.randint(0, 100),
            "let q = Raw::null<u8>();",
            "let mut n: i64 = 0; n = p__undefined__;",
        ])

    # ---- expressions ----
    def expr(self):
        r = self.rng
        self.budget -= 1
        if self.budget < 0:
            return str(r.randint(0, 100))
        pick = r.random()
        if pick < 0.30:
            return str(r.randint(-2**40, 2**40))
        if pick < 0.40:
            return "%s %s %s" % (self.expr(), r.choice(
                ["+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^"]), self.expr())
        if pick < 0.48:
            return "-%s" % self.expr()
        if pick < 0.56:
            return "(%s)" % self.expr()
        if pick < 0.62:
            return "%s(%s)" % (
                r.choice(["sizeof", "raw", "heap"]),
                self.expr() if r.random() < 0.5 else "i32")
        if pick < 0.70:
            return "Maybe-%s" % r.randint(0, 99)   # an unbound name
        if pick < 0.78:
            return '"%s"' % "".join(r.choice("ab{}\\\"\n\t") for _ in range(r.randint(0, 10)))
        if pick < 0.84:
            return "%s as %s" % (self.expr(), r.choice(
                ["i32", "i64", "u8", "f64", "bool", "raw u8"]))
        if pick < 0.92:
            return "%s.%s()" % (self.expr(), r.choice(
                ["read", "write", "plus", "minus", "is_null", "len", "next"]))
        return "%s.%s" % (self.expr(), r.choice(["v", "len", "cap", "x", "y"]))

    def boolexpr(self):
        return self.rng.choice([
            "true", "false",
            "%s %s %s" % (self.expr(), self.rng.choice(["==", "!=", "<", ">", "<=", ">="]),
                          self.expr()),
        ])


# --------------------------------------------------------------------------
# Adversarial specials: what plain grammar sampling will never stress.
# --------------------------------------------------------------------------

def specials(rng):
    """A fixed list of adversarial shapes (the fuzzer probes each; these were
    the classes that actually found bugs by hand — see fuzz findings)."""
    out = []

    def add(name, text):
        out.append((name, text))

    # Parser depth: the inferno found the SIGSEGV cliff
    d = 5000
    add("deep-parens",
        "fn main() -> i32 { return " + "(" * d + "1" + ")" * d + "; }\n")
    add("deep-blocks",
        "fn main() -> i32 { " + "{" * d + "}" * d + " return 0; }\n")
    add("deep-types",
        "fn f(x: " + "[" * d + "i32" + "]" * d + ") -> i32 { return 1; }\n"
        "fn main() -> i32 { return 0; }\n")
    add("deep-unary",
        "fn main() -> i32 { return " + "-" * d + "1; }\n")
    add("deep-generic-nest",
        "struct Box<T> { v: T; }\n"
        "fn main() -> i32 { let b: " + "Box<" * 300 + "i32" + ">" * 300 +
        " = 1; return 0; }\n")

    # Name-length & truncation edges (found the 512-byte lexbuf silence)
    add("long-identifier",
        "fn %s() -> i32 { return 1; }\nfn main() -> i32 { return 0; }\n"
        % ("a" * 5000))
    add("long-generic-instance",
        "struct " + "B" * 200 + "<T> { v: T; }\n"
        "fn main() -> i32 { let x: " + "B" * 200 + "<" + "B" * 200 +
        "<i32>>>" + " = 2; return 0; }\n")

    # Lexical boundary values
    add("int-limits",
        "fn main() -> i32 { let a = 2147483647; let b = -2147483648; "
        "let c = 9223372036854775807; let d = 18446744073709551615; "
        "return 0; }\n")
    add("radix-and-casts",
        "fn main() -> i32 { let a = 0xFF; let b = 0b1010; let c = 0o777; "
        "let d = 1_000_000; let e = 5u8; let f = 2.5f64; return 0; }\n")
    add("string-escapes",
        'fn main() -> i32 { let s = "a\\tb\\nc\\\\d\\"e\\0f\\u{1F600}"; return 0; }\n')
    add("nul-in-string",
        "fn main() -> i32 {\nlet s = \"abc\x00def\";\nreturn 0; }\n")

    # Structural mutants (robustness: the compiler must diagnose, not die)
    add("unbalanced-parens", "fn main() -> i32 { return (1; }\n")
    add("unbalanced-braces", "fn main() -> i32 { return 1;\n")
    add("stray-token", "fn main() -> i32 { return 1; }}\n")
    add("half-generic", "fn main() -> i32 { let x: Vec< = 1; return 0; }\n")
    add("namespace-garbage", "fn main() -> i32 { return a::b::c::d::e; }\n")
    add(" шампунь-unicode", "fn главная() -> i32 { return 0; }\n")   # non-ASCII ident
    add("empty-everything", "fn main() {}\n")
    add("big-array",
        "fn main() -> i32 { let a = [%s]; return 0; }\n"
        % ",".join(["1"] * 20000))
    add("many-locals",
        "fn main() -> i32 {\n%s\nreturn 0; }\n"
        % "\n".join("  let v%d = %d;" % (i, i) for i in range(5000)))

    # FFI/extern surface
    add("extern-shapes",
        'extern "C" fn abs_(x: i32) -> i32;\n'
        'extern "C" fn bad() -> &str;\n'       # must be rejected, not crash
        "fn main() -> i32 { return 0; }\n")

    # switch/pattern edge: variant lists, duplicate arms, zero variants
    add("enum-zero-variants", "enum Z { }\nfn main() -> i32 { return 0; }\n")
    add("switch-dup",
        "enum E { A, B }\n"
        "fn main() -> i32 { let e = E::A; switch (e) { "
        "case A: { return 0; } case B: { return 0; } case A: { return 1; } } "
        "return 0; }\n")

    # Recursion in resolution: types referencing themselves
    add("self-referential-type",
        "struct Node { next: Node; }\nfn main() -> i32 { return 0; }\n")
    add("self-referential-generic",
        "struct G<T> { v: G<T>; }\nfn main() -> i32 { return 0; }\n")

    # ranges & for
    add("range-weird", "fn main() -> i32 { for (i : 0..=0) { } for (j : 5..1) { } "
                       "for (k: -1..-1) { } return 0; }\n")

    # unchecked reason lengths
    add("unck-short-reason",
        'fn main() -> i32 { unchecked("no") { let p = Raw::null<u8>(); } return 0; }\n')

    return out


# --------------------------------------------------------------------------
# Token-level mutation engine.
# --------------------------------------------------------------------------

def load_corpus():
    files = []
    for d in CORPUS_DIRS:
        for dirpath, _, names in os.walk(d):
            for n in names:
                if n.endswith(".harmony"):
                    files.append(os.path.join(dirpath, n))
    return files


TOKEN_SPLIT = None  # simple whitespace+char split is enough for mutation


def tokens_of(text):
    return text.replace(";", " ; ").replace("{", " { ").replace(
        "}", " } ").replace("(", " ( ").replace(")", " ) ").replace(
        ",", " , ").split()


def mutate(text, rng):
    toks = tokens_of(text)
    for _ in range(rng.randint(1, 12)):
        if not toks or rng.random() < 0.1:
            break
        op = rng.random()
        i = rng.randrange(len(toks))
        if op < 0.25:                                    # delete a span
            j = min(len(toks), i + rng.randint(1, 6))
            del toks[i:j]
        elif op < 0.45:                                  # duplicate a span
            j = min(len(toks), i + rng.randint(1, 4))
            toks[i:i] = toks[i:j]
        elif op < 0.60:                                  # splice adversarial token
            toks.insert(i, rng.choice(
                [">>", "<<", "::", "<T>", "}", "{", "(", ")", ";",
                 "unchecked(\"reason\")", "&mut", "0..=", "Maybe<",
                 "case", "enum", "fn", "struct", "111111111111", "\""]))
        elif op < 0.75:                                  # swap two identifiers
            j = rng.randrange(len(toks))
            if toks[i][0].isalpha() and toks[j][0].isalpha():
                toks[i], toks[j] = toks[j], toks[i]
        else:                                            # overlong token
            toks[i] = toks[i] + toks[i] * rng.randint(2, 20)
    return " ".join(toks)


# --------------------------------------------------------------------------
# Oracles + driver.
# --------------------------------------------------------------------------

class Finding:
    def __init__(self, oracle, source, detail):
        self.oracle = oracle
        self.source = source
        self.detail = detail


def run_hb(args, stdin=None, timeout=TIMEOUT_COMPILER):
    try:
        p = subprocess.run([HB] + args, capture_output=True,
                           timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""
    except OSError as e:
        return "oserror", b"", str(e).encode()


def uses_unchecked(src_path):
    """True when the program opts into undefined behavior (§13).

    O4 compares the *observable* result across optimization levels. That is
    only a meaningful oracle for programs with an empty trusted surface: §13.6
    says UB can originate at any `unchecked` site, so a level-dependent
    behavior there is permitted, not a bug. (The earlier oracle flagged exactly
    that: a null store inside `unchecked` dies reproducibly at -O0 but is
    folded to `unreachable` at -O2 — legitimate UB, not a miscompile.)

    The test is deliberately the conservative one — a plain substring search,
    so a comment or a longer identifier that merely contains "unchecked" also
    causes a skip. Over-skipping costs coverage of one oracle; under-skipping
    produces false findings that waste a shrink pass and, worse, train the
    reader to ignore the oracle.
    """
    try:
        with open(src_path, "rb") as f:
            return b"unchecked" in f.read()
    except OSError:
        return True      # unknown input: don't claim a finding


def check_oracles(src_path, do_run=False):
    """Returns a Finding or None. src_path: the program to compile."""
    rc, out, err = run_hb(["check", src_path])
    if rc == "timeout":
        return Finding("O1-liveness(hang)", read_file(src_path),
                        "check timed out after %ss" % TIMEOUT_COMPILER)
    if rc == "oserror" or isinstance(rc, str):
        return Finding("O1-liveness(spawn)", read_file(src_path), str(rc))
    if rc < 0:
        # subprocess reports a signal death as a negative return code.
        return Finding("O1-liveness(signal)", read_file(src_path),
                       "check killed by signal %d" % -rc)
    if rc not in RECV_OK:
        return Finding("O1-liveness(crash)", read_file(src_path),
                       "check exit %r (stderr tail: %r)" % (rc, err[-200:]))

    rc2, out2, err2 = run_hb(["emit-llvm", src_path])
    if rc2 == "timeout":
        return Finding("O2-agreement(hang)", read_file(src_path),
                        "emit-llvm timed out (check was rc=%d)" % rc)
    if isinstance(rc2, str):
        return Finding("O2-agreement(spawn)", read_file(src_path), rc2)
    if rc == 0 and (rc2 not in (0,) or not out2):
        return Finding("O2-agreement", read_file(src_path),
                       "check ok but emit-llvm rc=%r len=%d" % (rc2, len(out2)))
    if rc != 0 and rc2 == 0 and out2:
        return Finding("O2-agreement", read_file(src_path),
                       "check rc=%d but emit-llvm produced IR" % rc)

    if rc == 0 and out2:
        # O3 determinism
        rc3, out3, _ = run_hb(["emit-llvm", src_path])
        if out3 != out2 or rc3 != rc2:
            return Finding("O3-determinism", read_file(src_path),
                           "second emit differs (len %d vs %d, rc %r vs %r)"
                           % (len(out2), len(out3 or b""), rc2, rc3))

    # O4 run-level consistency (only for programs with a clean `check`:
    # an empty trusted surface means behavior is fully defined, §13.6)
    if do_run and rc == 0 and not uses_unchecked(src_path):
        results = {}
        crashed = {}
        for opt in ("-O0", "-O2", "-O3"):
            r, _, rerr = run_hb(["run", src_path, opt], timeout=TIMEOUT_RUN)
            if isinstance(r, str):
                return Finding("O4-optlevel(liveness)", read_file(src_path),
                               "run %s: %s" % (opt, r))
            # `run` forwards the compiled program's exit status, which is
            # `main`'s value mod 256 — so 139 can mean "returned 139". A
            # signal death is reported the shell way (128+signal) *and* with a
            # diagnostic on stderr, which is what makes the two cases
            # distinguishable; the numeric code alone cannot.
            if r < 0:
                return Finding("O4-optlevel(signal)", read_file(src_path),
                               "run %s: driver killed by signal %d"
                               % (opt, -r))
            if b"killed by signal" in rerr:
                crashed[opt] = rerr.strip()[-80:]
                continue
            results[opt] = r
        if crashed:
            # O4 only runs on programs with an empty trusted surface, so their
            # behavior is fully defined (§13.6): a crash is never permitted,
            # whether it happens at every level or just some.
            return Finding("O4-optlevel(signal-in-program)",
                           read_file(src_path),
                           "program killed by a signal under %s: %r"
                           % (", ".join(sorted(crashed)), crashed))
        if len(set(results.values())) > 1:
            return Finding("O4-optlevel", read_file(src_path),
                           "exit codes differ across -O levels: %r" % results)

    return None


def read_file(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except OSError:
        return b""


# --------------------------------------------------------------------------
# Shrinking: reduce a failing input to a minimal repro (delta debugging).
# --------------------------------------------------------------------------

def maybe_shrink(text, oracle, args, tmpdir):
    """Shrinks unless --no-shrink, so smoke runs stay fast."""
    if getattr(args, "no_shrink", False):
        return text
    return shrink(text, shrink_oracle_for(oracle), tmpdir)


def shrink(src_text, oracle_fn, tmpdir, tries=200, budget_secs=20.0):
    """Greedy line-then-token removal. oracle_fn(path) -> Finding or None.

    Bounded two ways so a single giant finding can never dominate a campaign:
    a wall-clock deadline, and a cap on the token pass for very large inputs.
    Shrinking is best-effort — a partial shrink still makes a usable repro."""
    import time
    deadline = time.time() + budget_secs
    best = src_text
    path = os.path.join(tmpdir, "shrink_%d.harmony" % os.getpid())

    def out_of_time():
        return time.time() > deadline

    def fails(text):
        if out_of_time():
            return False
        with open(path, "wb") as f:
            f.write(text)
        return oracle_fn(path) is not None

    if not fails(best):
        return best   # not reproducible under the plain oracles; keep as-is

    # Pass 1: drop lines (cheap, high value).
    lines = best.split(b"\n")
    changed = True
    while changed and len(lines) > 1 and not out_of_time():
        changed = False
        i = 0
        while i < len(lines) and not out_of_time():
            cand = lines[:i] + lines[i + 1:]
            if fails(b"\n".join(cand)):
                lines = cand
                changed = True
            else:
                i += 1
    best = b"\n".join(lines)

    # Pass 2: token-level spans, only for modest inputs (the pass is ~O(n^2)
    # oracle calls; on a 20k-element special it would never converge).
    toks = tokens_of(best.decode("utf-8", "replace"))
    if len(toks) > 4000:
        return best
    changed = True
    while changed and tries > 0 and len(toks) > 1 and not out_of_time():
        changed = False
        tries -= 1
        i = 0
        while i < len(toks) and not out_of_time():
            cand = toks[:i] + toks[i + 1:]
            if fails(" ".join(cand).encode()):
                toks = cand
                changed = True
            else:
                i += 1
    return " ".join(toks).encode()


# --------------------------------------------------------------------------
# Parallelism. The compiler is single-threaded per invocation; the fuzzer gets
# throughput by running many independent compiler processes at once. Each
# worker owns a disjoint slice of the iteration space (seeded per worker, so
# the campaign is reproducible from --seed regardless of core count), writes to
# its own temp files, and returns findings; the parent shrinks and reports.
# --------------------------------------------------------------------------

def _worker_count(args):
    if args.jobs and args.jobs > 0:
        return args.jobs
    n = os.cpu_count() or 1
    return max(1, n)


# Per-worker context (set at pool init through initializer/fork inheritance).
_W = {}


def _worker_init(seed, tmpdir, run_generated):
    _W["rng"] = random.Random(seed)
    _W["tmpdir"] = tmpdir
    _W["run_generated"] = run_generated
    _W["tag"] = os.getpid()


def _task_gen(job):
    """One grammar-sampled program: generate, check all oracles, return finding."""
    idx, seed = job
    rng = random.Random(seed)
    g = Gen(rng)
    g.budget = rng.randint(5, 60)
    src = g.program()
    path = os.path.join(_W["tmpdir"], "gen_%d_%d.harmony" % (_W["tag"], idx))
    with open(path, "w") as f:
        f.write(src)
    fnd = check_oracles(path, do_run=_W["run_generated"])
    if fnd is None:
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    return ("gen-%d-%d" % (_W["tag"], idx), fnd.oracle, fnd.detail, src)


def _task_mut(job):
    """One token-mutated corpus program."""
    idx, seed, corpus_pick = job
    rng = random.Random(seed)
    text = read_file(corpus_pick).decode("utf-8", "replace")
    m = mutate(text, rng)
    path = os.path.join(_W["tmpdir"], "mut_%d_%d.harmony" % (_W["tag"], idx))
    with open(path, "w") as f:
        f.write(m)
    fnd = check_oracles(path, do_run=(idx % 20 == 0))
    if fnd is None:
        try:
            os.unlink(path)
        except OSError:
            pass
        return None
    return ("mut-%d-%d(from %s)" % (_W["tag"], idx, os.path.basename(corpus_pick)),
            fnd.oracle, fnd.detail, m)


def run_pool(tasks, worker_fn, seed, args, tmpdir):
    """Runs worker_fn over tasks across `jobs` processes, in completion order.

    Yields (name, oracle, detail, source) for every failure. Stops early if
    `args.max_findings` is reached (the pool is terminated cleanly)."""
    jobs = _worker_count(args)
    if not HAVE_MP or jobs <= 1:
        _worker_init(seed, tmpdir, args.run_generated)
        got = 0
        for t in tasks:
            r = worker_fn(t)
            if r is not None:
                yield r
                got += 1
                if got >= args.max_findings:
                    return
        return
    ctx = mp.get_context("fork") if hasattr(mp, "get_context") else mp
    pool = ctx.Pool(jobs, initializer=_worker_init,
                    initargs=(seed, tmpdir, args.run_generated))
    try:
        got = 0
        for r in pool.imap_unordered(worker_fn, tasks, chunksize=4):
            if r is not None:
                yield r
                got += 1
                if got >= args.max_findings:
                    pool.terminate()
                    return
    finally:
        pool.terminate()
        pool.join()


# --------------------------------------------------------------------------
# Engines.
# --------------------------------------------------------------------------

def engine_gen(args, tmpdir, findings):
    import time
    t0 = time.time()
    # Each task carries its own seed so the whole campaign is reproducible from
    # --seed independent of core count; the worker count only changes how the
    # work is distributed.
    base = args.seed * 1000003
    tasks = [(i, base + i * 7919) for i in range(args.iterations)]
    n_find = 0
    for name, oracle, detail, src in run_pool(tasks, _task_gen, args.seed, args, tmpdir):
        fnd = Finding(oracle, src.encode(), detail)
        sh = maybe_shrink(src.encode(), oracle, args, tmpdir)
        record_finding(findings, name, fnd, sh, tmpdir)
        n_find += 1
    secs = time.time() - t0
    print("engine gen: %d programs in %.1fs (%d jobs), %d findings"
          % (args.iterations, secs, _worker_count(args), n_find))


def shrink_oracle_for(oracle):
    """Oracle used while shrinking: keep only the class of failure stable."""
    prefix = oracle.split("(")[0]
    def fn(path):
        fnd = check_oracles(path)
        if fnd is None:
            return None
        if fnd.oracle.startswith(prefix):
            return fnd
        return None     # a different failure after shrinking: still interesting,
                        # but treat as "not failing" so shrinking continues.
    return fn


def engine_specials(args, tmpdir, findings):
    rng = random.Random(args.seed + 1)
    n_find = 0
    shp = specials(rng)
    for name, text in shp:
        path = os.path.join(tmpdir, "spec_%s.harmony" % name.replace("/", "_"))
        with open(path, "wb") as f:
            f.write(text.encode("utf-8", "replace"))
        fnd = check_oracles(path, do_run=True)
        if fnd is not None:
            sh = maybe_shrink(text.encode(), fnd.oracle, args, tmpdir)
            record_finding(findings, "spec-%s" % name, fnd, sh, tmpdir)
            n_find += 1
            if n_find >= args.max_findings:
                break
    print("engine specials: %d shapes, %d findings" % (len(shp), n_find))


def engine_mut(args, tmpdir, findings):
    import time
    corpus = load_corpus()
    if not corpus:
        print("engine mut: no corpus found")
        return
    rng = random.Random(args.seed + 2)
    base = args.seed * 2000003
    tasks = [(i, base + i * 104729, rng.choice(corpus))
             for i in range(args.iterations)]
    t0 = time.time()
    n_find = 0
    for name, oracle, detail, src in run_pool(tasks, _task_mut, args.seed + 2, args, tmpdir):
        fnd = Finding(oracle, src.encode(), detail)
        sh = maybe_shrink(src.encode(), oracle, args, tmpdir)
        record_finding(findings, name, fnd, sh, tmpdir)
        n_find += 1
    print("engine mut: %d mutants in %.1fs (%d jobs), %d findings"
          % (args.iterations, time.time() - t0, _worker_count(args), n_find))



def engine_afl(args, tmpdir, findings):
    """AFL++ in dumb mode over a curated corpus (the compiler cannot be
    instrumented; this is the beat-on-the-channel engine)."""
    import time
    afl = shutil.which("afl-fuzz")
    if not afl:
        print("engine afl: afl-fuzz not found, skipping")
        return
    outdir = os.path.join(tmpdir_for_afl(tmpdir), "out")
    indir = os.path.join(tmpdir_for_afl(tmpdir), "in")
    if os.path.isdir(indir):
        shutil.rmtree(indir)
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    os.makedirs(indir)
    # Seeds: a spread of the corpus + a couple of specials (small ones only).
    corpus = load_corpus()
    rng = random.Random(args.seed + 3)
    seeds = rng.sample(corpus, min(len(corpus), 40))
    n = 0
    for s in seeds:
        data = read_file(s)
        if len(data) > 8192:
            data = data[:8192]
        with open(os.path.join(indir, "seed_%03d.harmony" % n), "wb") as f:
            f.write(data)
        n += 1
    for name, text in (("paren", "(" * 500 + "1" + ")" * 500),
                      ("generic", "struct Box<T> { v: T; } fn main() -> i32 "
                                  "{ let b: Box<i32> = Box<i32> { .v = 1 }; return b.v; }")):
        with open(os.path.join(indir, "sp_%s.harmony" % name), "w") as f:
            f.write(text)
    cmd = [afl, "-i", indir, "-o", outdir, "-n",
           "-V", str(args.afl_seconds)]
    if args.afl_seconds <= 0:
        print("engine afl: disabled (afl-seconds=0)")
        return
    cmd += ["--", HB, "check", "@@"]
    print("engine afl: running %ds dumb-mode over %d seeds..."
          % (args.afl_seconds, n + 2))
    try:
        subprocess.run(cmd, capture_output=True, timeout=args.afl_seconds + 120)
    except subprocess.TimeoutExpired:
        pass
    # Replay every crash + hang through the full oracles.
    for kind in ("crashes", "hangs"):
        d = os.path.join(outdir, "default", kind)
        if not os.path.isdir(d):
            continue
        for fn_ in os.listdir(d):
            p = os.path.join(d, fn_)
            if os.path.isdir(p):
                continue
            fnd = check_oracles(p)
            if fnd is not None:
                sh = maybe_shrink(read_file(p), fnd.oracle, args, tmpdir)
                record_finding(findings, "afl-%s-%s" % (kind, fn_), fnd, sh, tmpdir)


def tmpdir_for_afl(tmpdir):
    return tmpdir


def engine_valgrind(args, tmpdir, findings):
    """A memcheck sample: the uninitialised-read oracle.

    Two invocations per sample, because a compiler has two interesting memory
    phases and valgrind can only watch one process tree at a time:

      * `check` exercises the front end + checker.
      * `emit-llvm` also exercises the backend's IR building.

    `run` is deliberately excluded: it forks clang and then the program, and
    the point of O5 is the compiler's *own* memory, not clang's.

    The sample mixes the real corpus with fresh `gen` output. The corpus is
    hand-written and misses whatever the sampler reaches; the generator is the
    only source of the adversarial *combinations* (deep generic nests,
    unchecked+raw, huge literals) where a compiler's memory bugs live. Half
    the budget goes to each so a campaign can never be fooled by sampling
    only the easy shape.
    """
    vg = shutil.which("valgrind")
    if not vg:
        print("engine valgrind: valgrind not found, skipping")
        return
    rng = random.Random(args.seed + 4)
    corpus = load_corpus()
    # Corpus half: concrete files already on disk.
    n_corpus = max(1, args.vg_sample // 2)
    paths = list(rng.sample(corpus, min(len(corpus), n_corpus)))
    # Generated half: written to the scratch dir so they outlive the run and a
    # finding has a real file to point at.
    n_gen = max(1, args.vg_sample - len(paths))
    for i in range(n_gen):
        grng = random.Random(args.seed + 4 + 977 * (i + 1))
        g = Gen(grng)
        g.budget = grng.randint(5, 60)
        src = g.program()
        p = os.path.join(tmpdir, "vg_gen_%d.harmony" % i)
        with open(p, "w") as f:
            f.write(src)
        paths.append(p)
    n_bad = 0
    n_ran = 0
    for c in paths:
        for sub in ("check", "emit-llvm"):
            # -q: quiet (only errors). --error-exitcode=99: any memcheck error
            # becomes 99, distinct from the compiler's own 0/1/2.
            try:
                p = subprocess.run(
                    [vg, "-q", "--error-exitcode=99", "--leak-check=no",
                     HB, sub, c],
                    capture_output=True, timeout=300)
            except subprocess.TimeoutExpired:
                record_vg_finding(findings, c, b"valgrind timeout")
                n_bad += 1
                if n_bad >= args.max_findings:
                    return _vg_report(n_ran, n_bad)
                continue
            n_ran += 1
            # 99 is memcheck's error code; a negative code or 99 must never be
            # produced by the compiler itself on a corpus file.
            if p.returncode == 99 or p.returncode < 0:
                record_vg_finding(findings, c, p.stderr)
                n_bad += 1
                if n_bad >= args.max_findings:
                    return _vg_report(n_ran, n_bad)
    _vg_report(n_ran, n_bad)


def _vg_report(n_ran, n_bad):
    # The count that matters is how many *runs* valgrind actually performed:
    # a misconfigured command line reports "0 findings" while doing nothing,
    # which is a false clean (this happened once with a bogus flag).
    if n_ran == 0:
        print("engine valgrind: ERROR no run completed, results are meaningless")
    else:
        print("engine valgrind: %d runs, %d with memory findings"
              % (n_ran, n_bad))


def record_vg_finding(findings, src_path, stderr):
    name = "vg-%s" % os.path.basename(src_path)
    entry = {
        "oracle": "O5-mem",
        "source": read_file(src_path),
        "detail": "valgrind: %r" % stderr[:2000],
        "shrunken": read_file(src_path),
        "orig": src_path,
    }
    findings.append((name, entry))


def record_finding(findings, name, fnd, shrunken, tmpdir):
    findings.append((name, {
        "oracle": fnd.oracle,
        "source": fnd.source,
        "detail": fnd.detail,
        "shrunken": shrunken,
    }))


# --------------------------------------------------------------------------
# Report.
# --------------------------------------------------------------------------

def report(findings, outdir, keep_all):
    if not findings:
        print("\nFUZZ CLEAN: no findings.")
        return 0
    os.makedirs(outdir, exist_ok=True)
    print("\n%d FINDING(S):" % len(findings))
    idx = 0
    for name, f in findings:
        idx += 1
        slug = "".join(ch if ch.isalnum() or ch in "._-" else "_"
                       for ch in name)[:80]
        base = os.path.join(outdir, "finding-%03d-%s" % (idx, slug))
        with open(base + ".harmony", "wb") as fh:
            fh.write(f["shrunken"] or f["source"] or b"")
        with open(base + ".txt", "w") as fh:
            fh.write("oracle:  %s\n" % f["oracle"])
            fh.write("name:    %s\n" % name)
            fh.write("detail:  %s\n" % f["detail"])
            fh.write("\n--- original (before shrink) ---\n")
            fh.write(repr(f["source"][:4000]))
            fh.write("\n")
        print("  [%s] %s -> %s" % (f["oracle"], name, base + ".harmony"))
    print("\nfindings written to %s" % outdir)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--jobs", type=int, default=0,
                    help="parallel workers (0 = one per CPU core)")
    ap.add_argument("--iterations", type=int, default=500,
                    help="programs per sampling engine (gen/mut)")
    ap.add_argument("--max-findings", dest="max_findings", type=int,
                    default=5, help="stop an engine after N findings")
    ap.add_argument("--engines", default="specials,gen,mut",
                    help="comma list: specials,gen,mut,afl,valgrind")
    ap.add_argument("--afl-seconds", dest="afl_seconds", type=int,
                    default=60, help="AFL dumb-mode time budget (0=off)")
    ap.add_argument("--vg-sample", dest="vg_sample", type=int, default=10,
                    help="corpus files through valgrind")
    ap.add_argument("--run-generated", dest="run_generated",
                    action="store_true",
                    help="also run generated programs (O4 opt-level oracle)")
    ap.add_argument("--out", default=None, help="findings directory")
    ap.add_argument("--keep", action="store_true",
                    help="keep the scratch dir (temp files)")
    ap.add_argument("--no-shrink", dest="no_shrink", action="store_true",
                    help="skip repro shrinking (fast smoke runs)")
    args = ap.parse_args()
    if args.seed is None:
        args.seed = random.randrange(2**32)

    if not os.path.exists(HB):
        print("error: %s not built (run 'make harmony-base')" % HB)
        return 2

    seed_note = "seed=%d" % args.seed
    print("harmony-base fuzzer (%s)" % seed_note)
    tmp = tempfile.mkdtemp(prefix="hbfuzz-", dir="/tmp")
    if not args.keep:
        atexit_tmp = tmp
    else:
        atexit_tmp = None

    findings = []
    import atexit
    if not args.keep:
        atexit.register(shutil.rmtree, tmp, ignore_errors=True)

    for e in args.engines.split(","):
        e = e.strip()
        if e == "specials":
            engine_specials(args, tmp, findings)
        elif e == "gen":
            engine_gen(args, tmp, findings)
        elif e == "mut":
            engine_mut(args, tmp, findings)
        elif e == "afl":
            engine_afl(args, tmp, findings)
        elif e == "valgrind":
            engine_valgrind(args, tmp, findings)
        else:
            print("unknown engine: %s" % e)

    outdir = args.out or os.path.join(ROOT, "tests", "fuzz2", "findings")
    return report(findings, outdir, args.keep)


if __name__ == "__main__":
    sys.exit(main())
