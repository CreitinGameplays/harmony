#!/usr/bin/env bash
# LISP interpreter tests (tests/harmony/lisp-interpreter/).
#
# A small LISP written in Harmony. The interpreter is split into
# value.harmony (values and the environment), reader.harmony (S-expressions),
# and eval.harmony (the evaluator), wired together with `import`
# (docs/harmony.md §6.7); each case generates a driver that imports them and
# runs a program, checking the result as the process exit code.
#
# The interpreter borrows the source string for symbols and reads from a
# compile-time literal, so the tests are
# deterministic and self-contained.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
D="$ROOT/tests/harmony/lisp-interpreter"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

if [ ! -x "$HB" ]; then
    echo "error: $HB not built (HARMONY=$HARMONY; run 'make all' first)" >&2
    exit 1
fi

# core = values + reader + evaluator, wired together with `import`
# (docs/harmony.md §6.7). The modules are copied into the temp dir so each
# generated driver imports them from its own directory.
cp "$D/value.harmony" "$D/reader.harmony" "$D/eval.harmony" "$TMP/"

# Emit a driver for `prog` and run it; the program is a compile-time literal.
gen_case() {
    local prog="$1"
    cat > "$TMP/case.harmony" <<EOF
import "value.harmony";
import "reader.harmony";
import "eval.harmony";

fn lisp_main(src: &str) -> i32 {
    let env = value::env_new();
    return value::as_int(&eval::eval_program(reader::read_all(src), &env));
}

fn main() -> i32 {
    return lisp_main("$prog");
}
EOF
}

check() {
    local name="$1" prog="$2" want="$3"
    gen_case "$prog"
    "$HB" run "$TMP/case.harmony" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        printf 'ok   %s (exit %s)\n' "$name" "$got"
    else
        fail=$((fail + 1))
        printf 'FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got"
    fi
}

# A crash is exit code >= 128 (a signal); every input must terminate cleanly.
# These feed malformed or hostile S-expressions through the reader+evaluator.
survive() {
    local name="$1" prog="$2"
    gen_case "$prog"
    "$HB" run "$TMP/case.harmony" >/dev/null 2>&1
    local got=$?
    if [ "$got" -ge 128 ]; then
        fail=$((fail + 1))
        printf 'FAIL %s (crashed, exit %s)\n' "$name" "$got"
    else
        pass=$((pass + 1))
        printf 'ok   %s (exit %s)\n' "$name" "$got"
    fi
}

# Integer literals and unary/negative reading.
check "integer literal"      "42"                                              42
check "negative literal"     "-7"                                             249   # -7 mod 256
check "symbol returns int"   "(define y 5) y"                                   5

# Arithmetic and nesting.
check "add"                  "(+ 1 2)"                                          3
check "variadic add"         "(+ 1 2 3)"                                        6
check "variadic multiply"    "(* 2 3 7)"                                       42
check "variadic subtract"    "(- 50 5 3)"                                      42
check "variadic divide"      "(/ 168 2 2)"                                     42
check "unary negate"         "(+ (- 50) 92)"                                   42
check "nested arithmetic"    "(* (+ 1 2) (- 10 4))"                            18
check "comparison true"      "(if (< 1 2) 42 0)"                               42
check "comparison false"     "(if (> 1 2) 0 42)"                               42
check "comparison in binding" "(define a (< 1 2)) (if a 42 0)"                 42
check "modulo"               "(% 100 30)"                                      10
check "bit and"              "(& 100 30)"                                       4
check "bit or"               "(| 34 8)"                                        42
check "bit xor"              "(^ 100 30)"                                     122
check "not of true"          "(if (not (< 1 2)) 0 42)"                         42
check "not of false"         "(if (not (> 1 2)) 42 0)"                         42

# Variables and the environment.
check "define then use"      "(define x 41) (+ x 1)"                           42
check "define shadow"        "(define x 1) (define x 42) x"                    42
check "closure captures"     "(define mk (lambda (n) (lambda (m) (+ n m)))) ((mk 40) 2)"  42
# The reader must not turn a lone `-` or a digit-leading token into a number.
check "lone dash is a symbol" "(define - 42) -"                                42
check "digit-leading symbol" "(define 1a 42) 1a"                               42
check "punctuated symbol"    "(define x? 42) x?"                               42

# Lists and quoting.
check "quote list"           "(define p (quote (40 2))) (+ (car p) (car (cdr p)))"  42
check "quote sugar"          "(define p '(40 2)) (+ (car p) (car (cdr p)))"          42
check "cons car cdr"         "(car (cons 42 7))"                              42
check "cdr"                  "(cdr (cons 7 42))"                               42
check "list builtin"         "(car (cdr (list 7 42)))"                         42

# Recursion (this is the interesting one for the shared environment).
check "factorial"            "(define f (lambda (n) (if (< n 2) 1 (* n (f (- n 1)))))) (f 5)"  120
check "fibonacci"            "(define g (lambda (n) (if (< n 2) n (+ (g (- n 1)) (g (- n 2)))))) (g 10)"  55

# Higher-order functions and mutable binding.
check "higher order"         "(define ap (lambda (f x) (f x))) (ap (lambda (n) (* n 2)) 21)"  42
check "mutual recursion"     "(define ev (lambda (n) (if (= n 0) 1 (od (- n 1))))) (define od (lambda (n) (if (= n 0) 0 (ev (- n 1))))) (ev 10)"  1
check "set! rebind"          "(define x 1) (set! x 42) x"                      42
check "set! counter"         "(define n 0) (define b (lambda () (set! n (+ n 1)))) (b) (b) (b) n"  3
check "closured counter"     "(define mk (lambda () (define n 0) (lambda () (set! n (+ n 1)) n))) (define c (mk)) (c) (c) (c)"  3
check "multi-form body"      "(define f (lambda (a b) (+ a 1) (+ b 1))) (f 40 41)"  42
check "sum a list"           "(define s (lambda (l) (if (nil? l) 0 (+ (car l) (s (cdr l)))))) (s '(10 20 12))"  42
check "curried closures"     "(define f (lambda (a) (lambda (b) (lambda (c) (+ a (+ b c)))))) (((f 1) 2) 39)"  42
check "ackermann"            "(define ack (lambda (m n) (if (= m 0) (+ n 1) (if (= n 0) (ack (- m 1) 1) (ack (- m 1) (ack m (- n 1))))))) (ack 2 5)"  13
check "build and sum 1..20"  "(define r (lambda (n) (if (= n 0) nil (cons n (r (- n 1)))))) (define s (lambda (l) (if (nil? l) 0 (+ (car l) (s (cdr l)))))) (s (r 20))"  210

# Malformed input must terminate cleanly (no signal): the reader sees
# unbalanced parens, stray closers, dangling quotes, and deep nesting.
survive "empty program"      ""
survive "unbalanced open"    "(+ 1 2"
survive "stray close"        ")))))"
survive "dangling quote"     "'"
survive "quote nothing"      "()"
survive "only parens"        "(((())))"
survive "define no value"    "(define x)"
survive "call a number"      "(42 1 2)"
survive "unbound symbol"     "totally-unbound"
survive "nested quote"       "(car ''(1 2))"
survive "many parens"        "$(printf '(%.0s' $(seq 1 40))$(printf ')%.0s' $(seq 1 40))"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
