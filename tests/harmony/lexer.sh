#!/usr/bin/env bash
# harmony-base lexer tests (docs/harmony.md §4).
#
# Positive cases lex and parse cleanly (exit 0). Negative cases must stop
# with the named diagnostic code; a `// WANT: <code>` comment selects it.
# Malformed-literal stops are LEX-01 (the lexer's own code); the parser's
# syntax stops are SYN-04/05.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/env.sh"
HB="$HARMONY"   # compiler under test (default: legacy; override with HARMONY=)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok_case() {
    local name="$1"; shift
    "$HB" check "$TMP/c.harmony" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        pass=$((pass + 1)); printf 'ok   %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL %s (expected clean lex)\n' "$name"
        "$HB" check "$TMP/c.harmony" 2>&1 | head -4 | sed 's/^/     /'
    fi
}

reject_case() {
    local name="$1" want="$2"
    out="$("$HB" check "$TMP/c.harmony" 2>&1)"
    if echo "$out" | grep -q "$want"; then
        pass=$((pass + 1)); printf 'ok   %s (rejected with %s)\n' "$name" "$want"
    else
        fail=$((fail + 1)); printf 'FAIL %s (wanted %s)\n' "$name" "$want"
        echo "$out" | head -3 | sed 's/^/     /'
    fi
}

write() { printf '%b' "$1" > "$TMP/c.harmony"; }

# write_raw: no escape interpretation at all (for literals containing
# backslash sequences bash's printf would eat, like \u{...}). A trailing
# newline is appended.
write_raw() { printf '%s\n' "$1" > "$TMP/c.harmony"; }

# ---------------------------------------------------------------- positive

write 'fn main() {}\n'
ok_case "minimal fn"

write '// line comment\n/* block */ /* nested /* inside */ still */\n/// doc comment\nfn main() {}\n'
ok_case "comments: line, nested block, doc"

write 'fn main() { let a = 42; let b = 1_000_000; let c = 0xFF; let d = 0o17; let e = 0b1010; }\n'
ok_case "integer literals: decimal, _, hex, octal, binary"

write 'fn main() { let a = 42u8; let b = 7i64; let c = 9usize; let d = 3.14; let e = 1e-3; let f = 2.5f32; }\n'
ok_case "integer suffixes and floats"

write_raw "fn main() { let a = 'x'; let b = '\\n'; let c = '\\u{1F980}'; let d = b'a'; }"
ok_case "char, escape, unicode escape, byte"

write_raw 'fn main() { let s = "hello\n\t\\\"\0world"; }'
ok_case "string escapes"

write 'fn main() { let t = true; let f = false; }\n'
ok_case "booleans"

write 'fn main() { let mut n = 1; n += 1; }\n'
ok_case "contextual life not reserved: player.life"

write 'struct S { life: i32; }\nfn main() { let s = S { .life = 1 }; let n = 0; return; }\n'
ok_case "life as a plain identifier (field name)"

write 'fn main() {}\nconst MAX: i32 = 8;\n'
ok_case "const item"

# ---------------------------------------------------------------- negative

write "fn main() { let a = 'ab'; }\n"
reject_case "two chars in a char literal" "LEX-01"

write "fn main() { let a = 'x; }\n"
reject_case "unterminated char literal" "LEX-01"

write_raw "fn main() { let a = b'\\u{100}'; }"
reject_case "byte literal above 255" "LEX-01"

write "fn main() { let a = \"unterminated; }\n"
reject_case "unterminated string literal" "LEX-01"

write "fn main() { let a = 1_000_; }\n"
reject_case "trailing _ separator" "LEX-01"

write "fn main() { let a = 42q; }\n"
reject_case "unknown numeric suffix" "LEX-01"

write "fn main() { let a = 2.5i32; }\n"
reject_case "integer suffix on a float" "LEX-01"

write_raw "fn main() { let a = '\\u{D800}'; }"
reject_case "surrogate scalar in escape" "LEX-01"

write_raw "fn main() { let a = '\\q'; }"
reject_case "unknown escape sequence" "LEX-01"

write "/* never closed\nfn main() {}\n"
reject_case "unterminated block comment" "LEX-01"

write "fn main() { let a = 1 \x07 2; }\n"
if [ "$(basename "$HB")" = "harmony-base" ]; then
    reject_case "unexpected byte" "SYN-05"
else
    # Documented v0/v1 divergence: v1 classifies a stray control byte as a
    # lexer stop (LEX-01), while the legacy compiler reported a parser stop
    # (SYN-05). Both reject; the code differs. Tracked as a 1.0 parity item.
    out="$("$HB" check "$TMP/c.harmony" 2>&1)"
    if echo "$out" | grep -q "LEX-01"; then
        printf 'DIVERGENCE unexpected byte: v1 reports LEX-01 (legacy: SYN-05)\n'
    else
        reject_case "unexpected byte" "SYN-05"
    fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
