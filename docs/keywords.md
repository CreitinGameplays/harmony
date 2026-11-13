# Harmony — keywords and builtins

Reference: `docs/harmony.md` §4 (lexical structure), §15 (standard library
surface). This file is the implementation checklist view: what the compiler
recognizes today vs. what the spec defines.

## Status

Nothing is lexed yet (M0 starts with the lexer); this table is the target
vocabulary the lexer and parser must recognize, per the v0.3 spec.

## Keywords (docs/harmony.md §4.2)

| Group | Keywords |
|---|---|
| Declarations | `fn` `let` `mut` `const` `struct` `enum` `methods` `copy` `export` `import` `extern` |
| Control flow | `if` `else` `while` `for` `switch` `case` `default` `return` `break` `continue` |
| Memory and safety | `new` `unchecked` `raw` `self` |
| Literals and operators | `true` `false` `as` `sizeof` |
| Contextual | `life` — keyword only in generic lists (`<life a>`) and types (`&life(a) T`, `Words<life(a)>`) |

`life` is contextual so `player.life -= 1;` still compiles (§4.2).

**Reserved for the future:** `abilities` `async` `await` `macro` `try`.
Dropped reservations (v0.3.1): `spawn`, `send` (concurrency will use
ordinary method-style names), and `trait` (the v1 trait-like feature is
spelled `abilities`, see docs/harmony.md §20.4).

**Recognized foreign words** (not keywords; the compiler knows them and emits
a `NAME-02` translation hint): `unsafe` `impl` `match` `trait` `pub` `use`
`loop` `goto` `null` `NULL` `nullptr` `malloc` `free` `Box` `Option` `Some`
`None` `Result` `Ok` `Err` `panic`.

## Builtins (docs/harmony.md §15)

| Name | Kind |
|---|---|
| `print` `println` `eprintln` | output |
| `trap` `assert` `exit` `leak` `drop` `swap` `replace` | control / ownership |
| `alloc` `dealloc` `reinterpret` | `unchecked fn`s (§13.2) |
| `Maybe` `Has` `Empty` `Outcome` `Good` `Bad` | prelude types |
| `String` `Vec` `Heap` `str` | owning / borrowed types |
| `.own()` `.or_trap()` `.clone()` `.take()` | methods |
| `Type::make()` | constructor convention (`new` is a keyword) |

## Diagnostic codes (docs/harmony.md §16.10)

The stable code set the checker may emit: `SYN-01..05`, `NAME-01..04`,
`SHADOW-01`, `TYPE-01..06`, `FMT-01`, `MUT-01..03`, `INIT-01`, `MOVE-01..04`,
`LOAN-01..03`, `LIFE-01..04`, `CASE-01..02`, `DROP-01..02`, `UNCK-01..05`,
`UNUSED-01..02`, `DEAD-01`, `STYLE-01`. The compiler-reserved code is `ICE-01`
(not in the spec catalogue; marks an internal invariant that must never fire).
