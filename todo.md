# Harmony — TODO

Legend: `[ ]` not started · `[/]` partial · `[x]` done.

This file tracks **two separate things**, and they must not be conflated:

1. **harmony-base** — the c2x-seed bootstrap compiler (`bootstrap/harmony-base/*.c2`).
   Freestanding and stdlib-free (AGENTS.md, docs/harmony.md §19.8): the bare
   minimum needed to express the `harmony` rewrite. This is what the section
   below is about.
2. **harmony — the final language** — the full-featured compiler written in
   harmony-base itself, plus `library/core/`, `library/alloc/` and
   `library/std/` (AGENTS.md).
   Its remaining feature work lives in its own section at the bottom and is
   **not** a harmony-base deliverable.

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
  - Token buffer was a fixed 256 bytes with no bounds check: a 256+-byte
    string literal / identifier silently overflowed into adjacent BSS and
    segfaulted the compiler. Now growable (heap, doubling via `lex_grow`),
    with keyword matching and token copies reading the live `tok_ptr`
    (regression `long_token_buffer.c2`). `EXIT_SUCCESS`/`EXIT_FAILURE` were
    `global` but never defined; now real symbols.
  - **`sys_wait4` lost its 4th argument.** The emitted `syscall_wait4` stub
    documented "4th arg in r10 per Linux syscall ABI" but never moved `rcx ->
    r10`, so the raw `syscall` read garbage from `r10` and returned `-EFAULT`.
    Latent until the arena spill began using inline-asm `mmap` (which sets
    `r10`), making the failure deterministic; found while fixing the compiler
    arena. The stub now moves `rcx -> r10` first (regression
    `tests/c2x-seed/cases/wait4_r10.c2`). No other stub takes a 4th argument.

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
  - **Slices** (`&[T]`, `&mut [T]`): a fat `{ ptr, i64 }` pair; `&a[lo..hi]`/
    `&a[..]`/`&a[..hi]`/`&a[lo..]`/`&a[lo..=hi]`, `lc_check_slice` (T-SLICE),
    runtime length indexing, `.len()`, re-slicing, by-value store/return.
    Exclusivity is part of the slice type: `&mut [T]` is distinct from `&[T]`,
    writable through, keeps its exclusivity when resliced, is not
    interchangeable with the shared form, and lowers with `noalias`.
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
    Call-site **inference** infers the type arguments when they are omitted:
    `id(7)` → `id<i32>(7)`; an uninferable parameter is a `TYPE-01` stop.
  - **`unchecked fn`** (§13.1): the documented
    `unchecked("contract") fn ...` item form now parses (it previously did
    not); the contract is kept on the fn node, callers still need a promise
    (UNCK-04), and the contract is an `audit` site.
  - **`harmony-base audit [file]`** (§13.6, §13.8): lists every `unchecked`
    block / fn with file, line, kind, reason, and span stats,
    `--format=json` included (`bootstrap/harmony-base/audit.c2`).
  - **Stack guard** (§14.2): SIGSEGV handler on an alternate stack. It reads
    `siginfo_t`/`ucontext` and reports `T-STACK` (exit 70) only when the fault
    is in the stack guard page; any other fault (a violated `unchecked`
    contract) re-raises, and `run`/`build` report the signal death by name as
    well as `128 + signo`, so it is never confused with a large exit value.
  - Quiet toolchain: clang stderr captured to a log; one-line summary + first
    error by default, `-v` replays the whole log.
  - Untyped literals adapt at every coercion site (§5.9), stamped on the node.
  - Tests: codegen.sh 73, error-handling.sh 33, checker.sh 28, parser.sh 55,
    lexer.sh 21, golden.sh 11, run.sh 41, fuzz.sh 24, determinism.sh 4,
    c2x-seed 26 + 3.

- [x] **M5 (driver part) — diagnostic model + renderers.**
  `code`/`severity`/`title`/`summary`/`story`/`fixes`; pretty (§16.2),
  `--format=line`, `--format=json`; ordering + caps (5 stops / 10 warns) +
  `…and N more`; `--strict`; `explain <CODE>`; driver codes have lessons.

### Remaining (harmony-base only)

- [x] Inferred generic calls: a call to a generic template without explicit
      `<...>` infers each type parameter from the argument types (`id(7)` ->
      `id<i32>(7)`, `max(a, b)` pins `T` and requires both to agree). An
      untyped literal adopts its default (`i32`/`f64`) before inference; an
      explicit `<...>` list still wins; a parameter no argument mentions is a
      `TYPE-01` stop asking for explicit arguments. (`ck_infer_generic_call`
      in cexpr.c2; `ck_unify` / `ck_ty_to_ast` in check.c2.)
- [x] Mutable-slice tracking (`&mut [T]`): the exclusivity of a slice is now
      part of its type (the `b` slot of the `CTY_SLICE` entry), so `&mut [T]`
      and `&[T]` are distinct and compare unequal. Writing through a `&mut
      [T]` parameter or field is allowed (MUT-01 no longer fires); reslicing a
      `&mut [T]` keeps it exclusive; a shared slice cannot stand in for an
      exclusive one or vice versa (both directions are `TYPE-01`); and the
      fat pair carries `noalias` like `&mut T`. This closes a real soundness
      gap (the two directions used to be silently accepted).
- [x] Minimal freestanding prelude the rewrite needs to compile `library/core/`:
      `trap(msg)`, `assert(cond[, msg])`, `unreachable()`, `exit(code)`
      (§15.1) lower to runtime hooks; the stopping ones are `never`-typed, so
      a function may end in them (`ck_block_ends_in_return` accepts a `never`
      tail) and the block ends with `unreachable`. `&str` parameters now spill
      as the fat pair (was a thin-pointer mis-spill). Remaining for the
      rewrite: a growable `String`/`Vec` over `heap` (needs an allocator grow
      hook).
- [x] `harmony-base audit [file]` — lists every `unchecked` site (block or
      `unchecked fn`) with file, line, kind, reason, line-span stats, and the
      under-12-char / over-10-line counts (§13.6, §13.8). `--format=json`
      emits one object per file. No input prints the empty listing (the CI
      gate case). Ran into and fixed a real parser bug: the documented
      `unchecked("contract") fn` item form (§13.1, §18) never parsed — the
      item parser only accepted `unchecked fn`. It now parses, stores the
      contract on the fn node, and still enforces UNCK-04 at call sites.
      (`bootstrap/harmony-base/audit.c2`, new; reports.c2 stub removed.)
- [x] In-memory LLVM IR (AGENTS.md): `build`/`run` feed the generated IR to
      clang on stdin (`clang -x ir - -x c rt.c ...`) through a pipe — no `.ll`
      temp file by default. New `sys_spawn_stdin` (c2x-seed gains a `pipe2`
      stub) writes the IR buffer to the child; `-v` keeps a `/tmp` copy for
      debugging a rejected IR. (`emit-llvm` still prints the IR to stdout.)
- [x] Multi-file compilation (`import`, §6.7): a new module loader
      (`bootstrap/harmony-base/module.c2`) eagerly loads the root file plus
      everything it imports (relative paths, dedupe by path, NAME-04 on a
      missing file or a cycle), merges the items into one flat program with
      imported items renamed `modname::name`, and the existing checker and
      LLVM path handle the rest. `export struct/enum` now parse (the marker
      was silently dropped before); qualified calls resolve module functions
      before enum/assoc forms, including *inferred* generic calls through a
      namespace (`geometry::id(7)`); merged type names mangle `::`→`__` in the
      IR. `--dump-ast` still skips resolution (parser round-trip tool).
      Bootstrap simplification: non-`export` items of imported modules merge
      too (private helpers stay callable); the final compiler's loader
      enforces visibility. Root-module lex/parse stops exit 1; an unreadable
      input exits 2, as before.
- [x] Safe process arguments (§15.6): `args() -> &[&str]` is the safe view of
      argv (no raw pointer). `_start` is a naked trampoline handing the
      initial `%rsp` to `lc_start`; `lc_args()` builds the static
      `&[&str]` view; the builtin lowers to a 16-byte copy from it.
- [x] Continue growing accept/reject suites per feature: cases exist for
      generic inference, mutable slices, `unchecked fn`, `audit`, `args()`,
      and multi-file imports (codegen 53 incl. `imports-main` with a
      transitive import; error-handling 31 incl. missing/cyclic imports).
      (The runtime `T-ASSERT` trap test: `tests/harmony/codegen/trap-assert`.)
- [x] Optimization levels (§19.5): `-O0/-O1/-O2/-O3/-Os/-Oz/-Og/-Ofast` (and a
      bare `-O` = `-O2`), passed straight through to clang's LLVM pipeline;
      **`-O2` is the default** when no flag is given. `build`/`run` use the
      level directly; `emit-llvm -O<level>` prints the *optimized* IR via a
      clang IR→IR round-trip (no new `opt` dependency, and the clang-only
      `-Og`/`-Ofast` work), while plain `emit-llvm` keeps printing our own
      byte-deterministic IR for the milestone check. An unrecognized `-O…`
      (e.g. `-O4`) is `usage.bad-opt`, not a generic unknown flag.
- [x] **`&str` and raw-pointer feature/bug fixes found probing a LISP
      interpreter.** (1) `&str` byte reads: `s[i]` is *not* integer-indexable
      (§5.2 — "the 3rd what?"), so it is now a `TYPE-02` stop; the documented
      byte view is `s.as_bytes() -> &[u8]` and text pieces come from
      `&s[lo..hi]`. (2) `&str`/slice `==`/`!=` compares *contents*
      (`lc_slice_eq`), not pair addresses. (3) Byte-range slicing `&s[lo..hi]`
      on a `&str` now yields a `&str` and traps (T-SLICE) when an end splits a
      UTF-8 code point (`lc_check_boundary`). (4) `.as_bytes()` is an intrinsic.
      (5) `char` participates in integer casts per §5.10 (`char as u32`,
      `u8 as char`). (6) An integer-literal suffix names its type
      (`let a = 5u8` is `u8`), and an array literal adapts its elements to a
      declared element type (`let a: [i64; 3] = [1, 2, 3]`). (7) `raw(&x)` /
      `raw(&mut x)` yield `raw T` / `raw mut T` (§13.5); a non-borrow operand
      is a `TYPE-02` stop. (8) Borrowing an rvalue (`&Val::A`) materializes a
      temporary instead of lowering to `ptr null`. Regression tests
      `str-bytes`, `literal-suffix-array-cast`, `borrow-rvalue`, `raw-create`,
      `str-index`, `raw-non-borrow`, `trap-str-slice-range`, `trap-str-boundary`.
- [x] `extern fn` FFI fixes found while assessing the rewrite's needs: a raw
      pointer compared against `0` now lowers to `icmp … ptr …, null` (LLVM
      rejected `… , 0`); an `extern fn` naming a prelude runtime hook (e.g.
      `lc_put_str`) no longer emits a duplicate `declare`, which LLVM rejects
      even with a matching signature. Regression tests `raw-null-cmp`,
      `extern-predeclared`.
- [x] **Five compiler/runtime bugs found building the LISP interpreter.**
      (1) *Literal-literal arithmetic.* A binary arithmetic expression whose
      operands are both untyped integer literals (`1 + 2`, `6 * 7`) was
      rejected with `TYPE-01` "arithmetic needs numbers": `ck_expr_binary`'s
      numeric gate tested `ty_is_integer`/`ty_is_float` but not
      `ty_is_untyped_lit`, so the literal-only case fell through. Fixed by
      accepting an untyped literal there; the result then defaults to `i32` as
      usual. Regression `tests/harmony/codegen/literal-arithmetic.harmony`.
      (2) *Missing freestanding memory builtins.* clang's optimizer lowers a
      large aggregate initialization/copy (e.g. `let a: [Val; 64] =
      [Val::Nil; 64]`) into a `memset`/`memcpy` libcall, and under
      `-ffreestanding -nostdlib` there is no libc to resolve it, so the link
      failed with "undefined reference to `memset'". The freestanding runtime
      (`bootstrap/runtime/rt.c`) now provides the standard `memset`/`memcpy`/
      `memmove`/`memcmp` (and `__bzero`) so any IR the compiler emits links.
      Regression `tests/harmony/codegen/big-aggregate-init.harmony`.
      (3) *Comparison stored in a binding.* `let a = (1 < 2);` recursed
      `ck_stamp_lits` through the `bool`-typed `<` node and stamped the literal
      operands with the comparison's *result* type (`i1`), so the backend
      emitted `icmp ult i1 1, 2` and `if (a)` disagreed with `if (1 < 2)`.
      `ck_stamp_lits` now stops at a node whose type is not numeric, so a
      comparison's operands keep their own width. Regression
      `tests/harmony/codegen/comparison-in-binding.harmony`.
      (4) *Integer-only operators reject untyped literals.* `100 % 30` (and
      `& | ^`) on two untyped integer literals was rejected with `TYPE-01`
      "integer-only operator" for the same reason as (1): the guard tested
      `ty_is_integer` but not `ty_is_untyped_lit`. Fixed; covered by
      `comparison-in-binding.harmony`.
      (5) *Import paths were not normalized.* A module's identity was the
      literal joined path, so the same file reached by two spellings
      (`"imports-rel/shared.harmony"` and
      `"imports-rel/nested/../shared.harmony"`) was two modules: loaded twice
      and merged twice, so the second merge collided with the first (`NAME-03`,
      "the name `shared::shared` is already used in this scope"). The loader
      now normalizes the path (collapsing `.` and resolving `..`) before using
      it as the identity, so one file is one module. Regression
      `tests/harmony/codegen/import-relative-paths.harmony`.
- [x] **`extern "C"` feasibility (answer: leave as is).** The external-function
      mechanism (declaration, call, UNCK gating, unmangled C-ABI symbol) is
      complete and sufficient for the next compiler: it already reaches the OS
      through the runtime's `lc_syscall3(n, a, b, c)` hook (open/read/write/
      close/getpid all work), and `&T as raw T` gives a C-ABI pointer that
      passes to a raw-pointer parameter. The only real gap is linking actual
      **libc** symbols, because the build is `-nostdlib -static` (freestanding)
      — and the rewrite does not need libc: it must stay freestanding like
      harmony-base. No change made.
- [x] **A small LISP interpreter in harmony-base
      (`tests/harmony/lisp-interpreter/`).** A robustness probe that exercises
      the M1 slice as a whole: recursive `Heap<T>` enums, pattern `switch` with
      boxed payloads, `&str` byte access and byte-range slicing, `&mut`
      receivers, a self-recursive evaluator, and a heap-shared mutable
      environment. Split into `value.harmony` (values, the frame-chain
      environment, list helpers), `reader.harmony` (S-expressions from a
      `&str`, recursive descent, quote sugar), `eval.harmony` (a fused
      `eval`/`apply` — one self-recursive function, since harmony-base has no
      forward declarations, so `eval`/`apply` cannot be mutually recursive —
      plus the variadic primitive procedures), and `main.harmony` (a driver).
      The modules are wired together with **`import`** (§6.7), not
      concatenation: `reader` and `eval` import `value`, `main` imports all
      three, and the cross-module names are spelled `value::Val`,
      `value::cons`, and so on. `make lisp` runs the driver directly;
      `make test-lisp` runs the 53-case suite in `tests/harmony/lisp.sh`
      (arith, closures, capture, `set!`, mutual recursion, ackermann, list
      processing, and malformed-input robustness), wired into `make test`. Each
      case generates its own driver that imports the modules, so the import
      path is exercised by every test. Five real compiler bugs fell out while
      building it (all fixed with regressions): literal-literal arithmetic
      (`1 + 2`), the missing freestanding memory builtins (`memset`/`memcpy`/…)
      that clang's optimizer emits under `-ffreestanding -nostdlib`, a
      comparison stored in a binding that typed its operands as `i1`, the
      integer-only `% & | ^` operators rejecting untyped literals, and import
      paths that were not normalized (the same file reached by two spellings
      was merged twice).
- [x] **Genuine blocking bugs found planning the `harmony` rewrite.** The
      rewrite's core loop is "read a byte buffer, index it, slice it", so these
      were fixed first, with regressions (each verified to fail before the fix):
      - **Heap-array indexing did not auto-dereference.** `h[i]` on a
        `Heap<[T; N]>` lowered to a GEP of the *heap box* instead of the
        pointee, so it read/wrote the wrong bytes and silently returned 0
        (§12.2/§5: `[]` auto-derefs through `Heap` exactly like `.`).
        `(*h)[i]` worked; now both do. Regression
        `tests/harmony/codegen/heap-array-index.harmony`.
      - **Slicing a heap array trapped.** `&h[a..b]` on a `Heap<[T; N]>` passed
        length 0 to `lc_check_slice` (it read the box, not the pointee), so it
        always trapped `T-SLICE`. `&(*h)[a..b]` worked; now both do.
        `.len()` on a heap array was rejected for the same reason (`TYPE-02`)
        and now folds to the constant length. Regression
        `tests/harmony/codegen/heap-array-slice.harmony`.
      - **`[v; N]` was lowered element-by-element.** The repeat array form
        emitted one store per element, so a `heap([0u8; 65536])` source buffer
        produced ~65k `store` instructions and exhausted the compiler arena
        (ICE-01) around N ≈ 58k; even N = 16384 emitted ~1.3 MB of IR. A
        repeat init with more than 64 elements is now a runtime fill loop (the
        old unroll is kept for small counts), so files that would not compile
        now do, the emitted IR is a constant size, and clang folds the loop to
        `memset` at -O2 (the runtime already provides it). Regression
        `tests/harmony/codegen/big-repeat-init.harmony`.
      - **Not blocking, deliberately left for M6** (workaround-able, so not
        fixed here): the §13.5 raw toolbox (`p.plus`/`p.minus`/`p.read`/
        `p.write`, `p.is_null`, `Raw::null<T>`, `alloc`/`dealloc`/
        `reinterpret`, `raw`-to-integer casts, `p[i]`) is unimplemented, and
        `&mut T` does not coerce to `&T` (write `&*r`). The rewrite can reach
        memory through an extern whose signature puts `raw u8`/`raw mut u8` in
        the pointer slot.
- [x] **Three genuine `f32` bugs found probing the C FFI.** Assessing a real
      `extern "C"` (all fixed; regression
      `tests/harmony/codegen/float32-arith.harmony`):
      - *`f32` arithmetic and comparison emitted `double`.* `ll_float_bin`
        hardcoded `ty = TY_F64`, so every `f32` operator lowered to
        `fadd`/`fcmp ... double` while its operands were `float`; LLVM rejected
        the IR ("'%x' defined with type 'float' but expected 'double'"), so any
        program that did `f32` math or compared two `f32`s failed to compile.
        The operand type is now threaded through. `f64` and untyped float
        literals (which default to `f64`) worked, which is why the bug hid.
      - *Inexact `f32` literals were emitted verbatim.* LLVM accepts
        `float 1.5` but rejects `float 1.66` ("floating point constant invalid
        for type"), so any `f32` literal not exactly representable in binary
        (`1.66`, `0.1`, `3.14`) failed to compile. The literal is now emitted
        at double precision and truncated (`fptrunc double 1.66 to float`).
      - *The float literal suffix was dropped at parse time.* A suffixed float
        was treated as untyped and defaulted to `f64`, so `let x = 1.5f32` was
        `f64` and `[1.0f32, 2.0f32]` (element type from the first element) was
        `[f64; 2]`; assigning the result to an `f32` was a `TYPE-01` stop. A
        suffixed float now names its type outright (§4.3), like an integer
        suffix. The AST node gains an `sfx` field to carry the suffix (it fits
        the existing 104-byte allocation and is copied by `ast_clone`).
- [x] **`extern fn` signature restriction enforced (§6.8).** The spec allows
      only primitives and `raw` pointers in a foreign signature, but the
      checker accepted anything and then emitted an ABI C does not use: a
      struct/enum by value went out through `sret` while C returns small
      (16 byte or less) values in registers (links, then silently returns wrong
      data); a fat reference (`&str`, `&[T]`) lost its length; a `Heap<T>`
      leaked an owned box across the boundary. `ck_register_extern` now
      validates every parameter and the return type, emitting `TYPE-02`
      ("not an FFI type") with the offending position and a fix. The supported
      shapes cover the freestanding OS surface: scalars, `raw T`/`raw mut T`
      (including `raw mut Struct` out-parameters, the POSIX `timeval`/`stat`
      shape), and a `void` return. Regressions:
      `tests/harmony/error-handling/ffi-struct-by-value.harmony`,
      `ffi-fat-reference.harmony`, `ffi-heap-param.harmony` (all verified
      wrongly accepted before the guard), and the positive
      `tests/harmony/codegen/ffi-signature-ok.harmony`.
- [x] **`extern` requires an ABI string (§6.8).** A foreign declaration now
      names the calling convention it uses: `extern "C" fn abs(x: i32) -> i32;`.
      The ABI is part of the declaration, never an implicit default:
      - `extern fn ...` without the string is a syntax error (`SYN-05`, "a
        foreign function needs an ABI") with a `try:` fix;
      - an ABI the backend does not implement is a stop (`FFI-01`, "unknown
        ABI") pointing at the string itself. `"C"` is the only one implemented
        today, because the emitted `declare` uses the C convention.
      The AST node gains an `abi` field (the node grew from 104 to 112 bytes,
      copied by `ast_clone`) and the ABI travels into the emitted IR as a
      comment (`; extern "C" abs`), so a reader of the `.ll` sees the
      convention. Regressions: `tests/harmony/error-handling/extern-missing-abi.harmony`
      (`SYN-05`), `extern-unknown-abi.harmony` (`FFI-01`), the positive
      `tests/harmony/codegen/extern-abi-ir.harmony`, and the
      `tests/harmony/golden/explain-ffi01` lesson. The tree-sitter grammar
      (language-extension, upstream `tree-sitter-harmony` a8a61a7) takes the ABI
      as a `string_literal` in a new `abi` field, so `extern fn ...` is now an
      ERROR there too.

### Feasibility probe: can the rewrite be written in harmony-base today?

The question "is harmony-base enough to write the full `harmony` compiler in
it?" was answered by compiling probe programs that exercise each construct a
compiler needs. **Verdict: not yet, but close.** The blocking items below are
grouped by whether they block the rewrite outright. Every claim is backed by a
probe run against the built compiler (kind: `check` = rejected/trap, `run` =
wrong exit code, or ICE) with a repro.

#### Blocking — must fix before the rewrite can start

- [x] **`const` was a silent miscompile (§6.2).** *(FIXED, commit `7075b63`.)*
      A constant used in *value* position lowered to a zero, not its value:
      `const A: i32 = 10; fn main() -> i32 { return A; }` returned `0`, and the
      emitted IR was literally `ret i32 0` — no diagnostic, `check` exited 0.
      `A` in a call argument, an `if` condition, or a `let` initializer all read
      0 where the constant's value belongs; `A + B` added `0 + 0`. Consts were
      only correct in *type* position (array length, via `ceval_const_int`).
      Worse, a const **array** indexed emitted `getelementptr ... ptr null` — a
      load through null (`run` trapped `T-STACK`). Root cause: the constant was
      registered as a symbol (`SK_CONST`) but never checked or lowered;
      `ll_expr_path`/`ll_addr` had no path for it and fell through to
      `ll_zero_of(ty)` / `"null"`.
      - *Fix*: the checker now requires a compile-time-evaluable initializer
        (`ck_is_const_expr`: literals, arithmetic on literals, another
        constant, array/struct literals) — anything else is the new `CONST-01`
        stop — and type-checks it (TYPE-01) and stamps untyped literals; the
        backend inlines the initializer at the use site (`ll_expr_path`,
        `ll_addr`, via `ck_sym_decl_node`).
      - *Tests*: `codegen/const-value.harmony` (scalar/arithmetic/chain/array/
        struct/&str/condition/loop/negative), `error-handling/const-call-init.harmony`
        (CONST-01), `error-handling/const-bad-init.harmony` (CONST-01 +
        TYPE-01), `golden/explain-const01`, plus the CONST-01 lesson and
        catalogue rows in `docs/harmony.md` §16.10 and `docs/keywords.md`.
- [x] **The compiler arena capped the program size (ICE-01).** *(FIXED.)*
      `harmony-base` kept a single fixed **16 MiB** arena (`g_arena[16777216]`,
      `bootstrap/harmony-base/util.c2`) that was never freed between functions,
      and the SSA-name/label helpers each `arena_alloc` (16/64 bytes) *per
      instruction* (`ll_new_reg`, `ll_new_label`), so memory grew with the
      generated code. The practical limit was **~1 MB of emitted IR**: a
      branch-heavy program of 145 functions compiled, 150 failed with
      `harmony-base: internal: arena exhausted (ICE-01)`.
      - *Fix*: the arena now has two regions. The fixed 16 MiB BSS block stays
        the fast path; when it fills, `arena_alloc` spills to `mmap`'d chunks
        (32 MiB each, grown as needed). The chunk is requested through the
        seed's `asm()` seam (the generated-binary runtime only emits the
        read/write/fork family, not mmap). Memory grows from the OS, so the
        ceiling is gone: a 3000-function / 33k-line program (21 MB of IR, far
        past `harmony-base` itself) now emits.
      - *Tests*: `tests/harmony/scale.sh` case `arena-past-16mib` (220
        branch-heavy functions, ~1.5 MB of IR), wired into `make test`. The
        regression was verified to fail (ICE-01) with the spill reverted.
      (Note: a true per-function reclamation would use even less memory, but
      the spill is enough to unblock the rewrite and keeps the fast path.)
- [x] **Function count was silently capped at 1024 (`g_fn_decl[1024]`).**
      *(FIXED.)* A program with more than 1024 functions registered only the
      first 1024 (`ck_fn_register_node` returned -1 past the cap with **no
      diagnostic**); every later function was still emitted, but the checker
      never resolved its return type, so its signature came out `void` —
      `define void @harmony__extra(i32)` for a function returning `i32`, and
      `define void @harmony_main()` for `main` — while the body still `ret i32`.
      clang then rejected the IR (`value doesn't match function result type
      'void'`): loud but confusing, and order-dependent.
      - *Fix*: the item registries are resizable (the documented "prefer auto
        resizable" rule). A shared `ck_grow` doubles `g_fn_decl`,
        `g_fn_self_ty`, the generic-template/instance tables, and the method
        table; the symbol table (`g_sym_*`, six parallel arrays) and the scope
        stack grow the same way. All `1024`/`4096`/`256` caps are gone.
      - *Tests*: `tests/harmony/scale.sh` cases `just-past-1024` and
        `past-1024-fns` assert the last function keeps its `i32` signature in
        the IR and that the program still runs; wired into `make test`. Both
        were verified to fail ("function N lost its i32 signature") with the
        cap restored.

#### Generic types and iteration — now implemented (the last rewrite blockers)

- [x] **Generic user-defined types (§5.7, §5.8, §6.4).** *(FIXED.)*
      `struct Box<T>`, `enum Opt<T>`, multiple parameters (`Pair<A, B>`),
      nested instances (`Box<Box<i32>>`), generic types as parameters and
      return types, and generic *methods* (`methods<T> Box<T> { ... }`,
      including associated `Type::make` functions) all work by
      monomorphization, mirroring the existing generic-function machinery.
      - *How*: a generic struct/enum declares a **type template** (recorded,
        not a type). The first `Box<i32>` use clones the template, substitutes
        the parameters in every field/variant payload, builds a fresh nominal
        type named `Box__i32`, and records the instance; later uses resolve to
        that one instance, so `ty_eq` (nominal, by name) makes them
        interchangeable and `Box<u8>` ≠ `Box<i32>`. Generic methods on a
        generic type are instantiated per concrete receiver
        (`ck_instantiate_gtmeth`); a bare `Box { ... }` inside a method body is
        rewritten to the instance's arguments (`ck_subst_ctor_args`).
      - *Parser*: `Box<i32> { ... }` (a generic struct literal) and
        `Opt<i32>::Some(3)` / `Opt<i32>::None` / `Box<i32>::make(...)` (a
        generic enum variant or associated function) are recognized by a new
        `p_looks_like_generic_type_use` lookahead (`>` followed by `{` or `::`),
        the §5.8 companion to the existing generic-call lookahead. Nested
        `>>` closing two levels is handled.
      - *Backend*: each instance emits as an ordinary `%struct.Box__i32` /
        `%enum.Opt__i32` definition (`ll_emit_type_def`), so no new lowering
        case was needed; only the instance list is walked.
      - *Tests*: `codegen/generic-types.harmony`, `generic-methods.harmony`,
        `generic-minivec.harmony` (§17.8's `MiniVec` end to end); plus
        error-handling `generic-missing-targs`, `generic-wrong-targ-count`,
        `generic-unknown-targ`, `generic-field-type`, `generic-instance-mismatch`.
      - *Not yet*: bounds (`<T: copy + ord>`) are parsed but not enforced on
        generic types/methods (they are on generic functions), and `copy` is
        not conditionally derived for a generic instance. Neither blocks the
        rewrite or the iterators below.
- [x] **The iteration protocol and ranges in `for` (§8.5, §6.6).** *(FIXED.)*
      `for (i : lo..hi)` / `lo..=hi` lower (bounds evaluated once, a fresh
      mutable binding, nested/`break`/`continue`), and any type with
      `fn next(&mut self) -> Maybe<T>` is now iterable: `for (x : it)` desugars
      to `loop { switch (it.next()) { case Has(x): body; case Empty: break; } }`
      in the backend (`ll_stmt_for_iter`), with the payload bound to the loop
      variable. The prelude enums `Maybe<T>` (Has/Empty) and `Outcome<T, E>`
      (Good/Bad) are registered as ordinary generic enums (§5.3), so bare
      `Has(5)`/`Empty`/`Good(x)`/`Bad(e)` resolve from the expected type (the
      `let` annotation or `return` type).
      - *A receiver bug found and fixed*: a method call on a reference-typed
        receiver (e.g. `self` inside a `&mut self` method calling
        `self.grow()`) passed the address of the `self` pointer slot instead of
        the pointee; the symbol also mangled from the reference (`&mut T`)
        rather than the auto-derefed `T`. Both are fixed
        (`ll_method_call`/`ll_method_recv_ty`); `generic-minivec.harmony` is
        the regression.
      - *Also fixed*: `RET-01` no longer fires when a function ends in
        `unchecked("...") { return ...; }` (or a returning `if`/`else`) — the
        idiomatic §13 shape.
      - *Tests*: `codegen/iteration.harmony`, `prelude-enums.harmony`,
        `for-range.harmony`, `generic-minivec.harmony`; error-handling
        `for-not-iterable`, `for-next-not-maybe`, plus the earlier
        `for-range-float-bound`, `range-not-a-value`.

#### Blocking for a self-hosted allocator (M6, workaround-able)

- [x] **The §13.5 raw pointer toolbox is implemented.** *(FIXED.)* The whole
      toolbox now works end to end, each operation gated by `unchecked`
      (UNCK-01) exactly where §13.2 says, and safe operations usable outside it:
      - `raw(&x)` / `raw(&mut x)` (already existed), `*p` read/write (existed),
        and now `p.read()`, `p.write(v)`, `p.plus(n)`, `p.minus(n)`, `p[i]`,
        `p.is_null()`, `p == q`, `Raw::null<T>()`, `raw`↔integer casts,
        `alloc<T>(n)`, `dealloc<T>(p, n)`, `reinterpret<T, U>(x)`,
        `Heap::into_raw(h)`/`Heap::from_raw(p)`, `v.get_unchecked(i)`.
      - Safe outside `unchecked`: creating (`raw`, `Raw::null<T>()`),
        `is_null`, comparison, and `Heap::into_raw` only-if-you-leak — all
        match the §13.5 table.
      - `Raw::null<T>()` yields `raw mut T` (the stronger form), and a new
        `raw mut T` → `raw T` coercion (discarding write capability is sound)
        lets it stand wherever a shared `raw T` is wanted, exactly as §17.8's
        `MiniVec` writes `MiniVec { .ptr = Raw::null(), ... }`.
      - The allocator hooks lower to `lc_alloc`/`lc_dealloc`; `reinterpret`
        requires equal sizes (`TYPE-01`) and lowers to a same-width bitcast or
        `ptrtoint`/`inttoptr`. `p.write`/`p[i]` through a `raw mut T` are
        allowed (the pointer's capability), like `*p = v`.
      - Tests: `codegen/raw-toolbox.harmony` (every operation, end to end) and
        error-handling cases `raw-read-outside-unchecked`,
        `raw-ops-outside-unchecked` (read/plus/index/cast all UNCK-01),
        `alloc-outside-unchecked`, `alloc-wrong-arity`, `dealloc-wrong-arity`,
        `reinterpret-size-mismatch`, `reinterpret-wrong-targs`.
- [x] **No runtime-sized allocation.** *(FIXED with the toolbox above.)*
      `alloc<T>(n) -> raw mut T` and `dealloc<T>(p, n)` now work: the count is
      scaled by `sizeof(T)` and lowered to `lc_alloc`/`lc_dealloc`. `lc_dealloc`
      is a no-op for the M1 bump allocator (`bootstrap/runtime/rt.c`; the OS
      reclaims at exit) and becomes real with the std allocator (§19.8.4). A
      growable buffer can now allocate a runtime-sized block instead of a fixed
      `Heap<[T; N]>`.

#### Not a gap (verified working — the rewrite's core can be written today)

These were probed specifically to find the boundary, and they work:
- Itself in miniature: a **context-threading** design (one `Ctx` struct
  holding a symbol table + arena, passed as `&mut Ctx` to every function)
  compiles and runs. This is how the rewrite must be written because —
- **There are no top-level mutable globals (§6.1, by design).** `let mut g`
  at item level is `SYN-05`. The spec is explicit ("Global state would break
  the exclusivity rule"), so this is a feature, not a bug: the rewrite threads
  state through one context (as `harmony-base` does via `g_*` in C). No action.
- Aggregates and methods: structs/enums by value, payload enums, nested
  enums-in-structs, `Heap<T>` recursive trees, `&mut self`/`self` methods,
  `methods` on any type, `switch` with payload binding, generic *functions*
  with `eq`/`ord` bounds and inference, `import` (including subdirs and `.hr`
  and qualified `mod::name`), `&str` (byte access, slicing, `==`, `.len()`),
  slices (`&[T]`/`&mut [T]`, `.len()`), `for (let ...)` C-style loops, and
  the freestanding prelude (`trap`/`assert`/`unreachable`/`exit`) all pass.

#### Repro commands (for whoever fixes these)

```sh
HB=./build/harmony-base
# 1. const silent-zero + const-array null read
printf 'const A: i32 = 10; fn main() -> i32 { return A; }\n' > /tmp/c.harmony
$HB run /tmp/c.harmony; echo "rc=$? (bug: 0, want 10)"   # IR shows `ret i32 0`
printf 'const T: [i32; 3] = [10,20,30]; fn main() -> i32 { return T[0]; }\n' > /tmp/ca.harmony
$HB run /tmp/ca.harmony; echo "rc=$? (bug: traps; IR has `getelementptr ... ptr null`)"
# 2. arena cap: ~150 branch-heavy fns (IR > 1 MB) -> ICE-01 at the default 16 MiB
#    (a generator printing 150 structs + 150 fns with 8 `if`s each)
# 3. 1024-fn cap: main past the cap -> 'define void @harmony_main()' + clang reject
# 4/5/6: all fixed — generic structs/enums/methods, `for (x : ...)` over an
# iterator, and `alloc<T>(n)`/`dealloc` now compile and run (see the sections
# above). `docs/harmony.md` §5.8 and §8.5 describe the implemented semantics.

### Cross-cutting

- [x] **Diagnostic codes `TYPE-03`/`TYPE-04` realigned to the catalogue.**
      `docs/harmony.md` §16.10 reserves `TYPE-03` for "condition is not
      `bool`" and `TYPE-04` for "wrong argument count or type", but the code
      emitted `TYPE-03` for arity and a generic `TYPE-01` for conditions —
      so the catalogue's condition diagnosis never fired. Now `ck_err_arity`
      and `ck_err_not_callable` emit `TYPE-04`, and a new `ck_err_condition`
      emits `TYPE-03` at every condition site (`if`/`while`/`for`, `assert`).
      Tests updated (`checker.sh`, `arity-simple`, `enum-construct-arity`,
      `generic-bad-targ-count`, `trap-no-arg`, `assert-non-bool`) and a new
      `error-handling/condition-not-bool.harmony`.
- [x] **c2x-seed migrated from NASM to flat assembler (FASM).** NASM spends
      ~26 s assembling the ~89k lines c2x-seed emits for `harmony-base` (the
      entire bootstrap), while FASM does it in ~0.15 s — a ~120× speedup that
      takes a full `make` from ~26 s to ~0.5 s. FASM objects are smaller (seed
      binary 740 KB → 309 KB) and byte-reproducible (FASM does not embed the
      input path, so the PID temp name never leaks). Both c2x-seed's own source
      and the assembly it *emits* moved to FASM syntax, and the driver now runs
      `fasm -m 262144 src obj` (the `-m` raises FASM's memory cap for the
      16 MiB arena; fasm cannot read source from stdin). The conversion is
      automated by `bootstrap/tools/nasm_to_fasm.py`; the pre-migration NASM
      sources are kept under `bootstrap/c2x-seed-nasm/`. The FASM child's
      stdout (its version banner) is redirected to `/dev/null` so builds stay
      quiet. `build.sh`, `Makefile`, `README.md`, `docs/c2x-seed.md`,
      `tests/c2x-seed/determinism.sh` updated; `make test` green (identical IR
      and byte-identical binaries vs the NASM build).
- [x] **Repository layout reorganized to the AGENTS.md target.** The stage-0
      compilers moved under `bootstrap/`: `bootstrap/c2x-seed/` (NASM),
      `bootstrap/harmony-base/` (c2x-seed), and `bootstrap/runtime/rt.c` (the
      freestanding runtime, was `src/stdlib/runtime/`). `src/` is gone; the
      self-hosted rewrite will live in the top-level `harmony/` (`lexer/`,
      `parser/`, `ast/`, `ir/`, `sema/`, `borrowck/`, `codegen/`, `driver/`,
      `main.hr`), with the standard
      library in `library/core/`, `library/alloc/`, and `library/std/`.
      `Makefile`, `build.sh`,
      `emit.c2`'s runtime path, `README.md`, `todo.md`, `roadmap/harmony-base`,
      and `docs/c2x-seed.md` all updated; empty target dirs are tracked with
      `.gitkeep`. `git mv` preserved history; `make test` green afterward.
- [x] `docs/harmony.md` realigned to the v0.3 rewrite; `docs/keywords.md`
      filled (keywords + builtins + code catalogue).
- [x] **Library layout split into `core/`, `alloc/`, `std/`** (AGENTS.md): the
      freestanding core is allocator-free, a separate `library/alloc/` holds
      the allocator hook `heap(x)` uses, and `library/std/` needs the OS. The
      empty directory is tracked with `.gitkeep`; `README.md` and the final
      language section below updated to match.
- [ ] Keep this checklist in sync as items complete.

---

## harmony — the final language

Deferred features. These are **not** harmony-base deliverables: they are
implemented in the `harmony` compiler (written in harmony-base) under
`harmony/` — the layout AGENTS.md now specifies:

- `harmony/lexer/`, `harmony/parser/`, `harmony/ast/`, `harmony/sema/`
  (semantic analysis), `harmony/ir/` (CFG IR), `harmony/borrowck/`
  (the borrow checker), `harmony/codegen/` (LLVM IR, C11), `harmony/driver/`
  (the CLI), and `harmony/main.hr`. The core is `*.hr`.
- `library/core/` (`*.hr`, freestanding-allowed): primitive types, slices,
  iterators — usable without an OS or allocator, like Rust's `core`.
- `library/alloc/` (`*.hr`): the allocator hook (`heap(x)` calls whatever
  allocator it exposes, so embedded targets can swap it).
- `library/std/` (`*.hr`): the full standard library (HashMap, io, fs, net)
  that needs the OS.
- `bootstrap/` holds the stage-0 compilers: `bootstrap/c2x-seed/` (NASM),
  `bootstrap/harmony-base/` (c2x-seed), and `bootstrap/runtime/` (the
  freestanding runtime only harmony-base links).

Also per AGENTS.md: the final `harmony` compiler must (a) integrate LLVM IR
directly into its binary and (b) support **multi-core compilation by default**.

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

- [ ] **Fuzzer gate before the rewrite**: `tests/fuzz2/fuzz.py` (5 engines,
      5 oracles, parallel) must run clean for a sustained campaign. It has
      already found and driven fixes for 10 real defects (13-digit literal
      stack overflow, exponential generic resolution, concurrent temp-path
      clobbering, SIGSEGV mislabeled `T-STACK`, uninitialized `dump_ast`,
      broken valgrind oracle, parser depth SIGSEGV, name truncation, quadratic
      instantiation, expected-type gaps in assignment/call/generic-call, and
      the method-name collision). `make test-fuzz2` is the fast gate;
      `make fuzz2-deep` a real campaign; `tests/harmony/coverage.sh` (in
      `make test`) guards that the grammar sampler keeps reaching the
      compiler's semantic stage.
- [/] **Rewrite the compiler in harmony-base (`harmony/`).** The phase plan,
  architecture decisions, and gates live in **`roadmap/harmony`** (read it
  first). Started 2026-11:
  - `library/core/` has its substrate: `mem.hr` (chunked arena),
    `vec.hr` (`Vec<T>`), `str.hr` (`String`, byte helpers), `fmt.hr`
    (diagnostics as data + line/json renderers). Unit-tested by
    `tests/harmony-final/` (in `make test`).
  - `harmony/lexer/` has a working scanner (`token.hr`, `ctx.hr`, `scan.hr`,
    `lit.hr`, `quoted.hr`). `tests/harmony-final/difftest.py` diffs its token
    stream against harmony-base's `--dump-tokens` on 31 snippets covering
    every token class; 0 mismatches. R2 is partial (the corpus is hand-written
    rather than every file in the repo).
  - `harmony/ast/node.hr` + `harmony/ast/print.hr`: the flat node model and a
    byte-identical `--dump-ast` printer, tested on the exact tree harmony-base
    prints for `fn main() -> i32 { return 42; }`. R3 is partial (the parser is
    not started).
  - Nine `harmony-base` gaps found and fixed while writing it (see
    `roadmap/harmony` "What harmony-base must still grow"): `for`-range
    element typing, `dealloc`/`Raw::null()`/`alloc` without `<T>`,
    struct-field expected types, `const` literal adoption, imported
    constants, method-name shadowing in the module loader, `u64` literals
    ≥ 2^63, and unsigned `%`. Each has a regression test.
  - Added the `str` lang item (`str::from_parts`), which §19.8.9 reserves,
    so a compiler can build a `&str` from owned bytes.
- [ ] Integrate LLVM IR emission directly into the compiler binary (AGENTS.md).
- [ ] Multi-core compilation by default (AGENTS.md).
- [ ] Byte-deterministic self-hosting milestone.
