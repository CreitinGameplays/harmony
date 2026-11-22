#!/usr/bin/env python3
"""A tiny reference interpreter for Harmony's safe integer subset.

This is the §19.6 differential oracle: for each fixture we ask the final
compiler to build and run it, then compare the process exit code with the
result of interpreting the same source here. The interpreter deliberately
supports only integers, `let`, assignment, `if`, `while`, and `return`: a bug
in it is obvious on inspection, which is the point of a reference model.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HC = os.path.join(ROOT, "build", "harmony")

TOKEN = re.compile(r"\s*(?:(\d+)|([A-Za-z_]\w*)|(==|!=|<=|>=|[+\-*/%<>=(){};:,]))")


def lex(src):
    out = []
    i = 0
    while i < len(src):
        m = TOKEN.match(src, i)
        if not m:
            if src[i].isspace():
                i += 1
                continue
            raise ValueError("unexpected byte %r" % src[i])
        i = m.end()
        if m.group(1):
            out.append(("num", int(m.group(1))))
        elif m.group(2):
            out.append(("id", m.group(2)))
        else:
            out.append(("op", m.group(3)))
    out.append(("eof", None))
    return out


class Parser:
    def __init__(self, src):
        self.toks = lex(src)
        self.i = 0

    def peek(self):
        return self.toks[self.i]

    def take(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def eat(self, text):
        if self.peek()[1] == text:
            self.i += 1
            return True
        return False

    def expect(self, text):
        if not self.eat(text):
            raise ValueError("expected %r, got %r" % (text, self.peek()))

    def expr(self, min_prec=0):
        kind, val = self.take()
        if kind == "num":
            left = ("num", val)
        elif kind == "id":
            left = ("var", val)
        elif val == "(":
            left = self.expr()
            self.expect(")")
        elif val in ("-", "+"):
            right = self.expr(4)
            left = ("neg", right) if val == "-" else right
        else:
            raise ValueError("bad expression start %r" % (kind, val))
        prec = {"==": 1, "!=": 1, "<": 2, "<=": 2, ">": 2, ">=": 2,
                "+": 3, "-": 3, "*": 4, "/": 4, "%": 4}
        while True:
            op = self.peek()[1]
            if op not in prec or prec[op] < min_prec:
                break
            self.take()
            right = self.expr(prec[op] + 1)
            left = ("bin", op, left, right)
        return left

    def block(self):
        self.expect("{")
        stmts = []
        while not self.eat("}"):
            stmts.append(self.stmt())
        return ("block", stmts)

    def stmt(self):
        if self.peek()[1] == "let":
            self.take()
            if self.peek()[1] == "mut":
                self.take()
            name = self.take()[1]
            self.expect("=")
            value = self.expr()
            self.expect(";")
            return ("let", name, value)
        if self.peek()[1] == "if":
            self.take()
            self.expect("(")
            cond = self.expr()
            self.expect(")")
            then = self.block()
            otherwise = None
            if self.eat("else"):
                otherwise = self.block()
            return ("if", cond, then, otherwise)
        if self.peek()[1] == "while":
            self.take()
            self.expect("(")
            cond = self.expr()
            self.expect(")")
            return ("while", cond, self.block())
        if self.peek()[1] == "return":
            self.take()
            value = self.expr()
            self.expect(";")
            return ("return", value)
        if self.peek()[0] == "id" and self.toks[self.i + 1][1] == "=":
            name = self.take()[1]
            self.take()
            value = self.expr()
            self.expect(";")
            return ("set", name, value)
        value = self.expr()
        self.expect(";")
        return ("expr", value)

    def program(self):
        # Skip everything before `fn main`, including comments stripped by lex.
        while not (self.peek()[1] == "fn" and self.toks[self.i + 1][1] == "main"):
            self.take()
        while self.peek()[0] != "eof" and self.peek()[1] != "{":
            self.take()
        return self.block()


class Return(Exception):
    def __init__(self, value):
        self.value = value


def ev(node, env):
    kind = node[0]
    if kind == "num":
        return node[1]
    if kind == "var":
        return env[node[1]]
    if kind == "neg":
        return -ev(node[1], env)
    if kind == "bin":
        _, op, a, b = node
        x, y = ev(a, env), ev(b, env)
        if op == "+": return x + y
        if op == "-": return x - y
        if op == "*": return x * y
        if op == "/": return int(x / y) if x * y >= 0 else -(-x // y)
        if op == "%": return x - (int(x / y) if x * y >= 0 else -(-x // y)) * y
        if op == "==": return int(x == y)
        if op == "!=": return int(x != y)
        if op == "<": return int(x < y)
        if op == "<=": return int(x <= y)
        if op == ">": return int(x > y)
        if op == ">=": return int(x >= y)
    raise ValueError("unsupported expression %r" % (node,))


def run_block(block, env):
    for stmt in block[1]:
        kind = stmt[0]
        if kind == "let":
            env[stmt[1]] = ev(stmt[2], env)
        elif kind == "set":
            env[stmt[1]] = ev(stmt[2], env)
        elif kind == "expr":
            ev(stmt[1], env)
        elif kind == "if":
            branch = stmt[2] if ev(stmt[1], env) != 0 else stmt[3]
            if branch:
                run_block(branch, env)
        elif kind == "while":
            while ev(stmt[1], env) != 0:
                run_block(stmt[2], env)
        elif kind == "return":
            raise Return(ev(stmt[1], env))
    return 0


def interpret(src):
    try:
        return run_block(Parser(src).program(), {}) & 0xFF
    except Return as r:
        return r.value & 0xFF


FIXTURES = [
    ("fn main() -> i32 { return 42; }", 42),
    ("fn main() -> i32 { let x = 7; return x + 3; }", 10),
    ("fn main() -> i32 { let mut x = 7; x = x * 2; return x; }", 14),
    ("fn main() -> i32 { let mut x = 1; return x; }", 1),
    ("fn main() -> i32 { if (1 == 1) { return 9; } return 0; }", 9),
    ("fn main() -> i32 { if (1 != 1) { return 9; } else { return 8; } }", 8),
    ("fn main() -> i32 { let mut x = 0; while (x < 5) { x = x + 1; } return x; }", 5),
    ("fn main() -> i32 { return 1 + 2 * 3 - 4 / 2; }", 5),
    ("fn main() -> i32 { let x = 20; let y = 6; return x % y; }", 2),
    ("fn main() -> i32 { let mut x = 3; if (x >= 3) { x = x + 4; } return x; }", 7),
]

FIXTURE_SOURCES = FIXTURES


def main():
    tmp = tempfile.mkdtemp(prefix="harmony-interp-")
    failures = 0
    for i, (src, expected) in enumerate(FIXTURE_SOURCES):
        path = os.path.join(tmp, "c%d.harmony" % i)
        with open(path, "w") as f:
            f.write(src + "\n")
        model = interpret(src)
        if expected is not None and model != expected:
            print("FAIL model %d: interpreter=%d expected=%d" % (i, model, expected))
            failures += 1
        proc = subprocess.run([HC, "run", "--jobs=1", path],
                              capture_output=True, text=True)
        if proc.returncode != model:
            print("FAIL differential %d: compiler=%d model=%d\n%s" %
                  (i, proc.returncode, model, (proc.stdout + proc.stderr)[:300]))
            failures += 1
    print("%d differential programs checked, %d mismatches" %
          (len(FIXTURE_SOURCES), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
