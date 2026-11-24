# Harmony — changelog and vocabulary map

This content was moved out of `docs/harmony.md` §1 so the language reference
stays about the language. Section references such as §19.8 or §20.3 still point
into `docs/harmony.md`.

## Version history

| Version | Theme | What changed |
|---|---|---|
| v0.1 | First draft | Ownership core, `life(a)` lifetime syntax, `new`, C-style parens and semicolons. |
| v0.2 | Rename pass | `impl`→`methods`, `match`→`switch`/`case`, `Option`/`Some`/`None`→`Maybe`/`Has`/`Empty`, `Box`→`Heap`, `for (x in v)`→`for (x : v)`. |
| v0.3 | Identity pass | New diagnostics format, `String::from`→`.own()`, constructors named `make`, `unchecked("reason")`, `raw` pointers, `extern "C" fn`, `export`/`import`, `cleanup` hook, `eq`/`ord` bounds, `next` iteration protocol, `Outcome`, byte literals, ranges. |
| v0.3.1 | Decisions + backends | §20.3 open questions resolved (structured reasons, guards, `Shared<T>`, threads incl. detached, early exit, named fields/struct patterns, function pointers, `i32` literals; `unchecked`-as-expression rejected); names kept, trait-like feature renamed **`trait`→`abilities`**, `spawn`/`send` un-reserved; **LLVM is the primary backend**, C11 secondary; the language is named Harmony (`.harmony`). The early-exit decision was later redesigned as the `else` clause (§20.3 item 5): `try` is not a keyword. |
| v0.3.2 | Heap form | The heap keyword `new` (a prefix operator: `new 42`) is replaced by the `sizeof`-styled built-in form **`heap(x)`**. It reads like the allocation it is, cannot be mistaken for a constructor, and lets the compiler construct the value **in place** (`heap([0u8; 8_000_000])`). `new` and `delete` join the recognized foreign words. |
| v0.3.3 | Split rule | §19.8 makes the compiler-vs-library boundary explicit: the compiler keeps only what soundness or syntax requires (analyses, traps, indexing, `heap(x)`, about a dozen intrinsics). Types, collections, formatting, I/O, the runtime's entry/allocator/trap formatting, protocol implementations, diagnostic wording, and lints all move to the library or tooling. |
| impl | M1 in harmony-base | The bootstrap compiler now **runs the language**: lexer → parser → type checker → LLVM IR text → clang + freestanding runtime → executable. Checked arithmetic (T-OVERFLOW), division/shift traps (T-DIV0, T-SHIFT), bounds-checked indexing (T-INDEX), `heap(x)` allocation, structs/enums by value (sret), methods with `Type__method` mangling, `switch` on scalars and enums, and references all work under `run` with trap status 70 (§14.3). `emit-llvm` output is byte-deterministic. |
| impl (rewrite) | R7 driver and self-host | `build/harmony` is built from the published stage-0 seed and rebuilt by itself so every canonical stage uses the same native backend schedule; stage 2 and stage 3 are byte-identical to stage 1. `make test` is a single lane; the old differential smoke gate is archived with the legacy toolchain. |
| impl (rewrite) | R8 native LLVM-C backend | `build`/`run` now link against `libLLVM` directly through `extern "C"` bindings (`library/std/llvm.hr`) and emit objects in parallel without spawning clang. `--backend=clang` keeps the old text/IR path for debugging, and `emit-llvm` is unchanged. |
| impl (rewrite) | v1 batch 1 | The final compiler accepts structured `unchecked(tag, "reason")` forms, guarded `switch` arms, and `Shared<T>`/`Weak<T>` from `library/std/shared.hr`. Audit reports tags; guards see bindings; shared ownership uses a control block with explicit `release` and `Maybe`-returning `upgrade`. These forms are final-language only; harmony-base stays v0. |
| impl (rewrite) | v1 threads | `library/std/thread.hr` adds joined and detached threads over raw `clone(2)` + futex hooks in `library/runtime/rt.c`. The `Share<T>` capability marker mints an opaque `ThreadArg` that `spawn` requires; `fnptr(f)` is the small final-only intrinsic for a function address. All three v1 gates pass; harmony-base stays v0. |
| impl (rewrite) | v1 `else` clause | The final compiler accepts `let x = f() else return;`, `else (e) { ... };`, `else continue;`, `else break;` and `else trap(...);` on `let`, plain `=` assignment, and expression statements. `try` is not a keyword; the success payload binds the target, `else return` forwards `Bad(e)`/`Empty`, and FLOW-01/02/03 reject fallthrough, mismatched errors, and impossible forwarding. These forms are final-language only; harmony-base stays v0. |
| impl (rewrite) | v1 patterns | The final compiler accepts named enum payload fields (`Variant { name: Type }`), named construction (`Enum::Variant { .name = value }`, positional still works), and struct patterns in `switch` (`case Point { x: 0, y: y }:`) with literal tests, bindings, qualified names and guards. Unknown fields are `TYPE-02`; a struct pattern on a non-struct/enum subject is `TYPE-01`. |
| impl (rewrite) | v1 function pointers | The final compiler accepts the structural `fn(Params) -> Ret` type. A declared function name used as a value produces a function pointer (annotation optional); signatures must match (`TYPE-01`) and indirect calls check arity (`TYPE-04`) and argument types. Pointers are `copy` and work in locals, fields, arrays and return positions. The separate `fnptr(name)` intrinsic still supplies opaque thread-entry addresses. |
| impl (rewrite) | v1 abilities | The final compiler accepts `abilities Name { fn sig; ... }` blocks and user-defined ability bounds (`<T: Drawable + ord>`). Satisfaction is structural: a type with matching methods has the ability; calls through a bounded parameter resolve to the concrete method after monomorphization. `ABLT-01`/`ABLT-02` report unsatisfied or unknown abilities, and a foreign `trait` block gets the `NAME-02` hint. harmony-base stays v0. |
| impl (rewrite) | M2 ownership | The final compiler runs definite-move dataflow over a CFG IR, validates `copy` declarations and `eq`/`ord` bounds, generates structural clone helpers, and elaborates drop glue with per-local drop flags. Cleanup hooks run once, `Vec` drops its elements and `Heap` its pointee. `MOVE-01/02/04`, `TYPE-05/06` and `DROP-01` cover the rejections. harmony-base stays v0; byte-identical IR is preserved for M2-neutral programs only. |
| impl (rewrite) | M3 borrowing | The final compiler computes reference liveness over the CFG and checks live loans against overlapping place accesses. `LOAN-01/02/03` cover shared-write, double-exclusive and read-under-exclusive conflicts; `MUT-03` rejects `&mut` of an immutable binding. Non-lexical lifetimes, reborrowing, disjoint fields, two-phase method calls and collection-wide element loans are supported. harmony-base stays v0. |
| impl (rewrite) | M4 lifetimes | The final compiler assigns compile-time regions to borrows, reference values and aggregates holding references. `life` parameters, `life(static)`, single-input/method-receiver elision, and structs/methods with named lives are supported; `LIFE-01..04` cover escaping locals, references that outlive their owner, ambiguous elision and signatures contradicted by the body. Lifetimes have no runtime representation or IR effect. harmony-base stays v0. |
| impl (rewrite) | M6 `unchecked`/FFI/audit | The final compiler gates all seven powers inside `unchecked`: raw use/arithmetic/index/casts, `extern`, `alloc`/`dealloc`, `reinterpret`, `get_unchecked`, `Heap::from_raw` and `unchecked fn` calls. Short reasons, long-block `UNCK-03` warnings, `--deny-unchecked` (`UNCK-05`) and `--strict` are enforced; `audit`/`audit --json` and explain lessons for every `UNCK-*` code are final-compiler features. Warnings go to stderr so `emit-llvm` stdout stays byte-identical. harmony-base stays v0. |
| impl (CI) | GitHub Actions release pipeline | `.github/workflows/ci.yml` builds and tests on pushes/PRs, and a manual `Release: tag` workflow creates a validated annotated release tag from the default branch (from `1.0.0` onward). The tag run rebuilds from the tag so `VERSION` is `stable`, packages source + binaries (with bundled LLVM/LLD runtime libraries and a relative RPATH) + SHA256SUMS, generates notes since the previous tag, and publishes a GitHub release. The legacy archive was published manually as `v0.3.3`; the stage-0 seed is published as `stage0-v1`. |
| impl (rewrite) | Library and tooling sweep | `harmony fmt` is the canonical token-based formatter (one style, comments preserved, idempotent). `library/core/prelude.hr` holds the prelude helpers the current backend can express; location-bound intrinsics stay in the compiler/runtime per §19.8.9. Golden snapshots cover pretty/ASCII/JSON output, a tiny reference interpreter differentially checks the safe integer subset, and the single-lane lexer/parser suites run strictly. `make fuzz2-deep` ran 2000 programs with no findings. The C11 backend and its sanitizer path remain deferred. |
| impl (rewrite) | M5 diagnostics polish | The final compiler stores story steps and fixes as diagnostic data. M2/M3/M4 analyses attach their event timelines, with right-aligned line numbers, 48-column source, 60-character labels and `file:line:col` for other-module steps. `--ascii` swaps glyphs, colour is decoration on a terminal only and honours `--no-color`/`NO_COLOR`, every STOP has a concrete `try:` fix, follow-on uses fold into the root report, and diagnostics sort by location with 5-stop/10-warn caps lifted by `--all`. All documented codes have full explain lessons, with harmony-base-compatible pages preserved. harmony-base stays v0. |
| design (future) | §20.5 scoped AST macros | Documented the intended macro system: expansion at stage 3.5, `#name(...)` calls, `expr`/`code`/`block`/`type`/`ident` parameter kinds, hygienic scopes, scoped `return`, variadic packs, `MACRO-01..04`, and the grammar extension. **Design only — no implementation, not in v1.** |
| impl (rewrite) | R6 LLVM backend | The self-hosted compiler now has its own LLVM IR emitter (`harmony/codegen/llvm/`). On all 95 programs in the codegen corpus, its IR was **byte-identical** to harmony-base's, including checked arithmetic, traps, slices, aggregates, generics, methods, enums, switches, formatting calls, and multi-module programs. |
| impl (bootstrap) | Seed-only build | The legacy `c2x-seed`/`harmony-base` toolchain was frozen on `legacy/bootstrap` (tag `legacy/bootstrap-final`) and archived as the `v0.3.3` release. The current seed is published separately on `stage0-v1`; `make harmony` downloads and verifies it before rebuilding the compiler. The latest compiler release always becomes the next seed. |
| impl (driver) | Verbose trace | `-v`/`--verbose` now reports each pipeline stage on stderr (bytes read, items parsed, stops checked, binary written), matching the legacy trace without changing stdout or exit codes. |
| version | 1.0.0 line opened | The `VERSION` base moved to `1.0.0` with the `beta` channel while the language is still being finished; the first seed-native final release is still `1.0.0`. |

## Bug fixed in v0.3

v0.2 used `new` as the heap-allocation keyword (`new 42`) **and** as the conventional constructor name (`Counter::new()`). Those cannot both parse, so v0.3 made constructors `Type::make()` and kept `new` as the heap keyword. v0.3.2 removes that obligation entirely: the heap form is `heap(x)`, so `new` is no longer a keyword at all (writing it earns a `NAME-02` hint).

## Vocabulary map

The core ideas (ownership, borrowing, lifetimes, exhaustive sum types) are not new; the surface is chosen to feel like C. This table maps the vocabulary so reviewers can see exactly what was changed and why.

| Idea | Common name elsewhere | Here | Why |
|---|---|---|---|
| Method block | `impl` | `methods Type { ... }` | Says what it is. |
| Pattern branching | `match` | `switch (x) { case P: { ... } }` | C-heads know it; ours is exhaustive with no fallthrough. |
| Optional value | `Option` / `Some` / `None` | `Maybe<T>` / `Has(x)` / `Empty` | Reads like English. |
| Fallible value | `Result` / `Ok` / `Err` | `Outcome<T, E>` / `Good(x)` / `Bad(e)` | Same. |
| Owning heap pointer | `Box<T>` | `Heap<T>` | "This lives on the heap." |
| Lifetime declare | `<'a>` | `<life a>` | No dangling `'`. |
| Lifetime use | `&'a T` | `&life(a) T` | Looks like `sizeof(x)`. |
| Whole-program lifetime | `'static` | `life(static)` | Same shape. |
| Escape hatch | `unsafe { }` | `unchecked("reason") { }` | Mandatory, auditable justification. |
| Raw pointer | `*const T` / `*mut T` | `raw T` / `raw mut T` | Keeps `*` for deref only. |
| Visibility | `pub` | `export` | Pairs with `import`. |
| Import | `use` | `import "path";` | C-like. |
| Abort | `panic!` | `trap(msg)` | A trap is a controlled stop, not an exception. |
| Force-unwrap | `.unwrap()` | `.or_trap("msg")` | The name says what happens. |
| Borrowed→owned | `String::from(s)` / `.to_string()` | `"Ada".own()` | One verb for "make me an owned copy". |
| Constructor convention | `Type::new()` | `Type::make()` | A constructor is a named `make`, not a keyword. |
| Heap allocation | `new x` / `Box::new(x)` | `heap(x)` | A built-in form, C-`sizeof` styled; `new` is a foreign word. |
| Destructor | `Drop` trait | `fn cleanup(&mut self)` | A special method name, no traits needed. |
| Iteration | `Iterator` trait | any type with `fn next(&mut self) -> Maybe<T>` | A structural protocol, no traits needed. |
| Traits (v1) | `trait` | `abilities` | An ability is what a type *has*; the bound syntax `<T: Drawable>` is already the shape. |
| Infinite loop | `loop {}` | `while (true) { }` | Already C. |
| Swap / replace / take | `mem::swap` etc. | `swap`, `replace`, `.take()` | Free functions in the prelude. |
| Compiler errors | `error[E0382]: ...` + carets | "Life story" timeline (see §16 of `harmony.md`) | Teaches ownership by narrating it. |

## What stayed the same on purpose

`let`, `let mut`, `&`, `&mut`, `*` (deref), `fn`, `struct`, `enum`, `const`, `copy` (marker), `Vec`, `String`, `str`, and `::` for paths. Familiar where familiarity is free, renamed where a rename improves reading.
