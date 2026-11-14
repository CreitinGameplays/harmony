# Harmony — TODO

Legend: `[ ]` not started · `[/]` partial · `[x]` done.

This file tracks **two separate things**, and they must not be conflated:

1. **harmony-base** — the c2x-seed bootstrap compiler (`src/harmony-base/*.c2`).
   Freestanding and stdlib-free (AGENTS.md, docs/harmony.md §19.8): the bare
   minimum needed to express the `harmony` rewrite. This is what the section
   below is about.
2. **harmony — the final language** — the full-featured compiler written in
   harmony-base itself, plus `src/core/` and the full `src/stdlib/`. Its
   remaining feature work lives in its own section at the bottom and is **not**
   a harmony-base deliverable.

Current state: **harmony-base is at M1 complete** — lexer → parser → type
checker → LLVM IR text → clang + freestanding runtime → runnable programs
(`emit-llvm`, `build`, `run`, `check`), byte-deterministic. Only a few small
bootstrap items remain.

---

## harmony-base — the bootstrap core

Target: the v0.3.2 design in `docs/harmony.md` (goals §2, lexical §4, types §5,
declarations §6, statements §8, traps §14, prelude §15, diagnostics §16,
grammar §18, architecture §19). Output extension: `.harmony` (default), `.hr`
(secondary). The primary backend is **LLVM IR** (§19.4, per AGENTS.md); the C11
backend is secondary (§19.4b) and belongs to the final language. The driver
binary is `harmony-base` (the spec's `lc`).

### Done

- [x] **M0 — Toolchain, layout, lexer, parser, AST printer (§19.7).**
  - Driver subcommands (`build`, `run`, `check`, `emit-llvm`, `emit-c`,
    `explain`, `audit`) and flags (`--format=pretty|line|json`, `--all`,
    `--strict`, `--deny-unchecked`, `--dump-ast`, `-o`, `-v`); exit codes
    (0 ok, 1 stop/warn-strict, 2 usage/IO, 70 program trapped).
  - Lexer (§4): UTF-8, nested comments, keywords + contextual `life`,
    `heap(x)` built-in, all literal forms, `LEX-01` with fixes.
  - Parser (§18): items, statements, all type forms, generics `<T, life a>`;
    `SYN-01..05` with fixes and recovery; `>>`/`>=` split, `..=` priority,
    `<...>(` generic-call lookahead.
  - AST pretty-printer (`pastout.c2`) + `--dump-ast`, deterministic.
  - Test harnesses: `run.sh`, `lexer.sh`, `parser.sh`, `golden.sh`,
    `fuzz.sh`, `determinism.sh`; c2x-seed corpus `tests/c2x-seed/`.

- [x] **M0.5 — c2x-seed fixes needed to build harmony-base.**
  (Full table: `docs/c2x-seed.md` "Recent Bug Fixes".)
  - Postfix index used `parse_unary`; now `parse_expression`.
  - Local/global struct arrays registered the count instead of the field array.
  - `&r->spans[i]` (address-of struct-array field via pointer) crashed.
  - Nested member chains (`b.a.x`, `o[i].inner.a`) miscompiled → recursive
    `gen_addr` lvalue-address helper.
  - `ARRAY_TYPE_FLAG` no longer collides with `struct N**`.
  - Pointer-to-struct members/indices at depth ≥ 2 lost field metadata.
  - Forward struct references (`struct A { struct B* b; }`).
  - Non-deterministic binaries (PID temp path leaked into the `FILE` symbol).
  - Compiler crash on undeclared indexed/address-of names.
  - Struct array stride sized arrays/by-value fields as one qword.
  - Infinite-size structs crashed; now a plain parse fault.
  - `g_g_` double prefix on global pointer loads (seven paths).
  - Member access on a call result (`f()->kind`) returned the address.
  - `g_p = g_arr` memcpy'd over the pointer variable; LHS classified first.
  - Undeclared identifiers compiled to silent garbage; now `report_undeclared`.
  - Pointer-array elements lost their pointee type, so `char* g[N]` double
    indexing scaled by the pointer stride (regression
    `char_ptr_array_double_index.c2`).

- [x] **M1 — Type checker + LLVM backend: "LLVM with types and traps" (§19.7).**
  - Checker for scalars, functions, structs, enums, `switch`, arrays,
    references, slices, `heap`, `sizeof`, casts, methods, generics. Codes
    `TYPE-01..06`, `MUT-01`, `INIT-01`, `CASE-01/02`, `NAME-01/03`, `RET-01`,
    `FMT-01`, `UNCK-01/02`, `RET-01` (checker.sh 24, error-handling.sh 17).
  - LLVM IR text (§19.4 mapping): checked arithmetic via
    `llvm.*.with.overflow` + `lc_trap`, division/shift traps, `main` →
    `harmony_main`, `extern fn` declares, control flow;
    **byte-deterministic** output, mangling `harmony__name`.
  - Aggregates (struct/enum/array) lowered as addresses; by-value params/
    returns via `sret`; indexing + `lc_check_index` (T-INDEX); methods and
    associated calls (`Type__method`); casts (`as`); `heap(x)` + `lc_alloc`;
    `&T`/`&mut T` (`noalias` on `&mut`); `switch` on scalars and enums;
    payload enums (`Enum::Variant(args)` construction and `case V(w, h)`
    payload binding, §6.4/§6.5; payload at byte offset 8, tag region 8 bytes).
  - **Slices** (`&[T]`): a fat `{ ptr, i64 }` pair; `&a[lo..hi]`/`&a[..]`/
    `&a[..hi]`/`&a[lo..]`/`&a[lo..=hi]`, `lc_check_slice` (T-SLICE), runtime
    length indexing, `.len()`, re-slicing, by-value store/return.
  - **Recursive `Heap<T>` trees** (§12): `Heap<T>` resolves in type position;
    `heap(x)` memcpy's aggregate values into the allocation; switching through
    `&`/`Heap` unwraps to the pointee; `Heap<T>` coerces to `&T` at call
    sites; unqualified variant construction `Has(x)` resolves against
    in-scope enums (ambiguity rejected); bare unit variants (`Empty`) build
    the tagged value; nominal-type registration is two-pass, so §12.3's
    mutually recursive `Maybe`/`Node` works; aggregate places borrow to `&T`
    at call sites.
  - **`extern fn` FFI** through `unchecked` (UNCK-01/02/05); `lc_syscall3`
    proves the C ABI without a libc.
  - **`FMT-01`** (§15.1): `print`/`println`/`eprintln` format strings parsed
    and checked at compile time, lowered to `lc_put_*` hooks
    (`{}`/`{:5}`/`{:.2}`/`{:05}`/`{:x}`, `{{`/`}}`); `&str` literals work.
  - **Generic monomorphization** (§18): `id<i32>(x)` clones the template,
    substitutes type parameters through the body, registers a concrete
    `name__Ty` instance (deduped, identifier-safe symbols, bounded params).
  - **Stack guard** (§14.2): SIGSEGV handler on an alternate stack → `T-STACK`
    (exit 70); `run`/`build` report signal deaths as `128 + signo`.
  - Quiet toolchain: clang stderr captured to a log; one-line summary + first
    error by default, `-v` replays the whole log.
  - Untyped literals adapt at every coercion site (§5.9), stamped on the node.
  - Tests: codegen.sh 48, error-handling.sh 24, checker.sh 24, parser.sh 53,
    lexer.sh 21, golden.sh 9, run.sh 28, fuzz.sh 24, determinism.sh 4.

- [x] **M5 (driver part) — diagnostic model + renderers.**
  `code`/`severity`/`title`/`summary`/`story`/`fixes`; pretty (§16.2),
  `--format=line`, `--format=json`; ordering + caps (5 stops / 10 warns) +
  `…and N more`; `--strict`; `explain <CODE>`; driver codes have lessons.

### Remaining (harmony-base only)

- [ ] Inferred generic calls: `id(x)` without explicit `<T>` (type inference).
      Needed for ergonomic self-hosting; until then every generic call spells
      its type arguments.
- [ ] `noalias` on `&mut [T]` slices (the mutability of the fat pair is not
      tracked yet).
- [x] Minimal freestanding prelude the rewrite needs to compile `src/core/`:
      `trap(msg)`, `assert(cond[, msg])`, `unreachable()`, `exit(code)`
      (§15.1) lower to runtime hooks; the stopping ones are `never`-typed, so
      a function may end in them (`ck_block_ends_in_return` accepts a `never`
      tail) and the block ends with `unreachable`. `&str` parameters now spill
      as the fat pair (was a thin-pointer mis-spill). Remaining for the
      rewrite: a growable `String`/`Vec` over `heap` (needs an allocator grow
      hook).
- [ ] `harmony-base audit` — list every `unchecked` site with reason (§13.6);
      today it returns an empty listing (needs M6 surface).
- [ ] In-memory LLVM IR (AGENTS.md): compile the generated IR by feeding it to
      clang on stdin instead of writing a `.ll` temp file by default. The
      current driver writes `/tmp/harmony-base.ll` then passes the path; the
      IR text is already a buffer (`g_out`), so this is a plumb-through.
- [ ] Continue growing accept/reject suites per feature; add a runtime
      `T-ASSERT` trap test once `assert` exists.

### Cross-cutting

- [x] `docs/harmony.md` realigned to the v0.3 rewrite; `docs/keywords.md`
      filled (keywords + builtins + code catalogue).
- [ ] Keep this checklist in sync as items complete.

---

## harmony — the final language

Deferred features. These are **not** harmony-base deliverables: they are
implemented in the `harmony` compiler (written in harmony-base) under
`src/harmony/`, with the core library in `src/core/` (freestanding-allowed
primitives, slices, iterators) and the full standard library in `src/stdlib/`
(needs the OS/allocator).

### Language semantics

- [ ] **M2 Ownership**: moves (`MOVE-01..04`), `copy` bounds (`TYPE-05/06`),
      `.clone()`, `Heap<String>`/`Vec`/`cleanup`, drop flags (§9.5),
      `MOVE-02` loop moves, re-initialization (§9.7); moves dataflow over the
      CFG IR (§19.2) and the **event log** (`born`, `moved`, `used`, …) for
      story diagnostics (§19.3).
- [ ] **M3 Borrow checker**: loans `(place, kind, region)`, liveness-based
      regions (§10.2, §19.2), `LOAN-01..03`, reborrowing (§10.5), disjoint
      fields (§10.6), two-phase borrows (§10.7), borrowing from collections.
- [ ] **M4 Lifetimes**: `life` parameters, `life(static)`, elision (§11.3),
      inference + region constraints (`LIFE-01..04`).
- [ ] **M6 `unchecked`, `raw`, FFI, audit**: the seven-powers gate (§13.2),
      blast-radius warn (`UNCK-03`), calling an `unchecked fn` outside a block
      (`UNCK-04`), `audit`/`audit --json` (§13.6), raw pointer operations.

### Diagnostics polish (compiler UX, beyond the driver part above)

- [ ] Glyph fallbacks `--ascii` (§16.3); color, honoring
      `--no-color`/`NO_COLOR` (decoration only).
- [ ] Full `explain` corpus: one lesson per code (WHAT/WHY/BAD/GOOD/NOTE/SEE).
- [ ] Story alignment: right-aligned line numbers, trimmed 48-column source,
      60-char labels, other-file steps (`lib/x.src:3:5`) (§16.2/16.3).
- [ ] Cascade control (§16.9): type errors suppress ownership analysis in the
      same function; `also used at …` folding.
- [ ] Every STOP carries ≥1 `try:` fix (§16.1; enforced by tests).

### Standard library and backends

- [ ] **Split rule** (§19.8): keep only soundness/syntax glue + ~a dozen
      intrinsics in the compiler; move types (`Vec`/`String`/`Heap`/ranges/
      iterators), numeric method families, formatting/IO, the runtime entry +
      allocator + trap formatting, protocol impls (`next`/`cleanup`/`clone`/
      `eq`/`cmp`/`show`), diagnostic wording, and lints into the library or
      tooling.
- [ ] Prelude: `print`/`println`/`eprintln` (+ `{?}`/`{:.N}`), `trap`,
      `assert`, `exit`, `leak`, `drop`, `swap`, `replace`.
- [ ] `String`/`.own()`, `Vec`, `Heap`, `Maybe`/`Has`/`Empty`,
      `Outcome`/`Good`/`Bad`, `str` slices + char-boundary traps (§14.1).
- [ ] Iteration protocol: `fn next(&mut self) -> Maybe<T>` (§6.6, §8.5).
- [ ] **C11 backend** (`emit-c`, §19.4b): same mapping semantics via host `cc`;
      cross-check against the LLVM path.
- [ ] `lc fmt`: canonical formatter (§19.5).
- [ ] Test strategy (§19.6): ≥3 reject programs per code; snapshot tests incl.
      `--ascii`/`--format=json`; ASan/UBSan fuzzing of non-`unchecked` C
      output; differential tests against a reference interpreter.

### Self-hosting

- [ ] Rewrite the compiler in harmony-base (`src/harmony/`).
- [ ] Byte-deterministic self-hosting milestone.
