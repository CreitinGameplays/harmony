# Harmony — keywords and builtins

Reference: `docs/harmony.md` §4 (lexical structure), §15 (standard library
surface). This file is the implementation checklist view: what the compiler
recognizes today vs. what the spec defines.

## Status

The lexer (§4) and parser (§18) are implemented (M0): the tables below are
the vocabulary they recognize. `new` is no longer a keyword (v0.3.2): the
heap form is the built-in `heap(x)` (docs/harmony.md §12.2).

## Keywords (docs/harmony.md §4.2)

| Group | Keywords |
|---|---|
| Declarations | `fn` `let` `mut` `const` `struct` `enum` `methods` `copy` `export` `import` `extern` |
| Control flow | `if` `else` `while` `for` `switch` `case` `default` `return` `break` `continue` |
| Memory and safety | `unchecked` `raw` `self` |
| Literals and operators | `true` `false` `as` `sizeof` `heap` |
| Contextual | `life` — keyword only in generic lists (`<life a>`) and types (`&life(a) T`, `Words<life(a)>`) |

`life` is contextual so `player.life -= 1;` still compiles (§4.2).
`heap` is a built-in **form** like `sizeof` (§12.2), not a general keyword:
`heap(x)` is a primary expression.

`extern` is followed by an **ABI string** and then `fn`:
`extern "C" fn abs(x: i32) -> i32;` (§6.8). The string is mandatory — an
`extern fn` without one is a syntax error — and `"C"` is the only ABI the
backend implements (`FFI-01` for any other name).

**Reserved for the future:** `abilities` `async` `await` `macro`. (`try` was dropped: v1 early exit is an `else` clause. `macro` is reserved for the future scoped AST macro design in docs/harmony.md §20.5 — design only, no implementation.)
Dropped reservations: `spawn`, `send` (concurrency uses ordinary method-style
names), `trait` (the v1 trait-like feature is spelled `abilities`, see
docs/harmony.md §20.4), and `try` (v1 early exit is an `else` clause, §20.3
item 5). Dropped keyword (v0.3.2): `new` — the heap form is `heap(x)`.

**Recognized foreign words** (not keywords; the compiler knows them and emits
a `NAME-02` translation hint): `unsafe` `impl` `match` `trait` `pub` `use`
`loop` `goto` `null` `NULL` `nullptr` `malloc` `free` `new` `delete` `Box`
`Option` `Some` `None` `Result` `Ok` `Err` `panic`, plus `define` (as `#define`) and `macro_rules` (as `macro_rules!`) — §16.11, §20.5.

## Builtins (docs/harmony.md §15)

| Name | Kind |
|---|---|
| `print` `println` `eprintln` | output |
| `trap` `assert` `exit` `leak` `drop` `swap` `replace` | control / ownership |
| `args` | process arguments (`args() -> &[&str]`, §15.6) |
| `alloc` `dealloc` `reinterpret` | `unchecked fn`s (§13.2) |
| `Maybe` `Has` `Empty` `Outcome` `Good` `Bad` | prelude types |
| `String` `Vec` `Heap` `str` | owning / borrowed types |
| `.own()` `.or_trap()` `.clone()` `.take()` | methods |
| `sizeof(T)` `heap(x)` `raw(x)` | built-in forms |
| `fn(Params) -> Ret` | v1 final-compiler type: a structural, `copy`, pointer-sized function pointer; a declared function name coerces to it when the signature matches (see `harmony.md` §5.11) |
| `fnptr(name)` | v1 final-compiler intrinsic: address of a declared function as `raw u8`, used for thread entries; harmony-base does not parse it |
| `else` (on a simple statement) | v1 final-compiler clause: `let x = f() else return;`, `x = f() else (e) { ... };`, `f() else trap("...");`. Only `Maybe`/`Outcome`; see FLOW-01/02/03 |
| named payload / struct pattern | v1 final compiler: `enum E { V { f: T } }`, `E::V { .f = x }`, and `case V { f: p }:` / `case S { f: p }:` in `switch` |
| future `#` / `...` | reserved tokens for §20.5 macros: `#name(...)` invocation, `items: expr...` packs and `pack...` spreads; not implemented in v1 |
| future contextual `expr` `code` `block` `type` `ident` | macro parameter kinds in §20.5, only after `:` in a macro parameter list; not implemented in v1 |
| `str::from_parts(p, len)` | the `str` lang item (§19.8.9): build a `&str` from owned bytes + length; needs `unchecked` because the pointer is unchecked. Used by `library/core`'s `String::as_str`. |
| `Type::make()` | constructor convention (a named `make`, not a keyword) |

**Split rule (docs/harmony.md §19.8):** only the `sizeof`/`heap`/`raw`
forms, the trap-and-pointer intrinsics, and the syntax glue are compiler
concerns. `print`/`println`/`format`, the collections, the numeric method
families, I/O, and the runtime entry/allocator are **library** code. The
compiler recognizes their hook *names and shapes* (`next`, `cleanup`,
`clone`, `eq`, `cmp`, `show`), never their implementations.

## Diagnostic codes (docs/harmony.md §16.10)

The stable code set the checker may emit: `SYN-01..05`, `NAME-01..04`,
`SHADOW-01`, `TYPE-01..06`, `FMT-01`, `FFI-01`, `CONST-01`, `MUT-01..03`, `INIT-01`,
`MOVE-01..04`, `LOAN-01..03`, `LIFE-01..04`, `CASE-01..02`, `DROP-01..02`,
`UNCK-01..05`, `UNUSED-01..02`, `DEAD-01`, `STYLE-01`. The compiler-reserved
code is `ICE-01` (not in the spec catalogue; marks an internal invariant that
must never fire).
