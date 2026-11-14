# Harmony — TODO

Legend: [ ] - Not implemented; [/] - Partially implemented; [x] - Fully implemented.
Update todo.md accordingly.

Status legend: `[ ]` not started · `[/]` partial · `[x]` done.

---

## harmony-base — detailed implementation checklist

`src/harmony-base/*.c2` — the first Harmony compiler, written in c2x-seed.
Target: the v0.3.2 design in `docs/harmony.md` (goals §2, lexical §4, types §5,
declarations §6, statements §8, ownership §9–13, traps §14, prelude §15,
diagnostics §16, grammar §18, architecture §19).
Output extension: `.harmony`. Milestone: byte-deterministic build.
The primary backend is **LLVM IR** (§19.4, per AGENTS.md); the C11 backend is
secondary (§19.4b). The driver binary is `harmony-base` (the spec's `lc`).

### M0 — Toolchain, layout, lexer, parser (§19.7) — COMPLETE

- [x] `Makefile` rules: `harmony-base` (build compiler), `test`, `test-seed`,
      `test-fuzz`, `clean`; `build.sh` (c2x-seed) is a prereq of the compiler.
- [/] `src/harmony-base/` file layout (each file < ~1500 lines; split
      aggressively, subdirs welcome):
  - [x] `common.c2` — shared declarations (types + cross-module prototypes).
  - [x] `main.c2` — driver: subcommands, flags, exit codes (§19.5, §16.6).
  - [x] `source.c2` — source manager: file load, line index, offset→line/col.
  - [x] `diag.c2` — diagnostic model + pretty/line/json renderers (§16).
  - [x] `util.c2` — arena allocator, string helpers, out/err helpers.
  - [x] `ast.c2` — AST node definitions + arena-backed resizable child lists.
  - [x] `reports.c2` — `explain` lessons (§16.8) + `audit` listing (§13.6).
  - [x] `lexlit.c2` + `lexer.c2` — full lexer (§4): keywords/contextual
        `life`, all literal forms, nested comments, LEX-01 stops.
  - [x] `parser.c2` + `pstmts.c2` + `pexpr.c2` — recursive-descent parser
        (§18), SYN-01..05 with fixes, recovery, `pastout.c2` pretty-printer.
  - [ ] `resolve.c2` — module loader + name resolution (§19.1 stage 3).
  - [ ] `types.c2` — type checker + `copy`/`eq`/`ord` bounds (§5, §19.1 stage 4).
  - [ ] `lower.c2` — CFG IR: places, moves, borrows, scope ends (§19.1 stage 5).
  - [ ] `flow.c2` — definite init, moves, liveness, loans, life (§19.1 stage 6).
  - [ ] `drops.c2` — drop elaboration + drop flags (§19.1 stage 7).
  - [ ] `mono.c2` — monomorphization (§19.1 stage 8).
  - [ ] `emit_llvm.c2/` — LLVM IR text emission (§19.1 stage 9, §19.4).
        **Priority** (AGENTS.md): the primary backend; deterministic, readable
        symbols, `--emit-llvm`.
  - [ ] `emit_c.c2/` — C11 emission (§19.4b). Secondary; the portable
        cross-check backend (`emit-c`), after the language is exercised.
  - [ ] `rt.c` — the runtime library (both `rt.bc` and `rt.h`, §19.4).
  - [ ] `exhaust.c2` — pattern-matrix exhaustiveness (`CASE-01/02`).
- [x] Driver subcommands (§19.5): `build`, `run`, `check`, `emit-llvm`,
      `emit-c`, `explain <CODE>`, `audit`; flags `--format=pretty|line|json`,
      `--all`, `--strict`, `--deny-unchecked`, `--ascii`, `--no-color`,
      `-o`, `-v`.
      (`check` runs the real pipeline; codegen commands stop with `ICE-01`
      until the LLVM backend lands.)
- [x] Exit codes (§16.6): `0` ok, `1` any STOP (or WARN under `--strict`),
      `2` usage/IO error, `70` the compiled program trapped (§14.3).
- [x] Deterministic build: no timestamps/PIDs/paths in output; stable symbol
      names. Fixed the c2x-seed PID-in-`FILE`-symbol bug (see
      `docs/c2x-seed.md`); guarded by `tests/harmony/determinism.sh`.
- [x] Test harness: golden fixtures under `tests/harmony/golden/`; diff stdout +
      exit code byte for byte via `tests/harmony/golden.sh`.
- [x] `tests/harmony/run.sh` + `tests/harmony/fuzz.sh`; registered in Makefile.
- [x] `tests/c2x-seed/run.sh` (+`faults/` negative cases) and
      `tests/c2x-seed/determinism.sh` — c2x-seed corpus (`make test-seed`).
- [x] Lexer (§4): UTF-8 ingest; nested `/* */` + `//` + `///` comments;
      identifiers; keywords + contextual `life` (stays an identifier;
      `life(...)` recognized in type position); `heap(x)` as a built-in
      form (`new` is no longer a keyword, §12.2 v0.3.2); integer/float/bool/char/byte
      literals (incl. `1_000`, `0xFF`, `'a'`, `b'a'`, `\u{...}`);
      `-`/`;` punctuation rules; position tracking. Missing `;` → `SYN-04`;
      malformed literals → `LEX-01` with a fix. (`lexlit.c2` + `lexer.c2`.)
- [x] Parser (§18): items (`export`/`import`/`fn`/`const`/`struct`/`enum`/
      `methods`/`extern fn`/`unchecked fn`); statements (`let [mut]`,
      assignment as statement, `if`/`while`/`for` 3 shapes/`switch`/`return`/
      `break`/`continue`/`unchecked("...")` blocks); types (`[T; N]`, `[T]`,
      `&T`, `&mut T`, `&life(a) T`, `raw [mut] T`, generics `<T, life a>`);
      conditions parenthesized (else `SYN-01`); braces mandatory (else `SYN-02`);
      assignment-in-condition → `SYN-03`; recovery at `;` and `}` (plus a
      no-progress guard so a malformed item cannot loop forever).
      (`parser.c2` + `pstmts.c2` + `pexpr.c2`.)
      Notable grammar details handled: `>>`/`>=` split for nested generics
      (`Vec<Vec<i32>>`), `..=` before `..` in the lexer, `<...>(` lookahead
      for generic calls, `eq`/`ord` bounds as identifiers (`copy` is the
      only keyword bound), `self` as a primary expression.
- [x] AST pretty-printer + round-trip tests (§19.7 M0 deliverable).
      `pastout.c2` + `--dump-ast` (deterministic output); golden AST shapes
      in `tests/harmony/parser.sh`; lexer suite `tests/harmony/lexer.sh`
      (both registered in `make test`).

### M0.5 — c2x-seed fixes required to build harmony-base

These c2x-seed defects were found and fixed while bootstrapping (see
`docs/c2x-seed.md` "Recent Bug Fixes" for the full table):

- [x] Postfix index expressions used `parse_unary`; now `parse_expression`.
- [x] Local struct arrays registered element count instead of the field array.
- [x] `&r->spans[i]` (address-of struct-array field via pointer) crashed.
- [x] Nested struct member chains (`b.a.x`, `c.b.a.x`, `o[i].inner.a`) were
      miscompiled; added a recursive `gen_addr` lvalue-address helper.
- [x] Global struct arrays of array-bearing structs emitted a doubled `g_` prefix.
- [x] Type-flag collision: `struct N**` encoded the same as a struct array
      (`ARRAY_TYPE_FLAG` now sits above all pointer encodings).
- [x] Pointer-to-struct members/indices at depth ≥ 2 lost field metadata and
      mis-scaled indices (`pp[i]->field`, `l->items[i]->kind`).
- [x] Forward struct references (`struct A { struct B* b; }` with `B` later)
      failed to parse; placeholder + back-patch support added.
- [x] Non-deterministic binaries: the PID-unique temp `.asm` path leaked into
      the output's `FILE` symbol; nasm now reads the temp file via
      `/dev/stdin` (added `sys_dup2`).
- [x] Compiler crash on an undeclared indexed/address-of name
      (`x[i]`, `&x[i]`, `&x`, `x[i] = v`): the index/address-of fast paths
      leaked a pushed pointer on the not-found branch, growing the codegen
      stack until it read off the end.
- [x] Struct array stride too small: `struct_total_size` sized array and
      by-value struct fields as one qword, so `struct B { int n; int arr[3]; }`
      came out 16 bytes instead of 32 and array indexing hit the wrong element.
- [x] Compiler crash on infinite-size structs (`struct G { struct G s; }`,
      `struct G { struct G arr[2]; }`): by-value self-reference during body
      parsing now reports a plain parse fault instead of recursing forever.
- [x] `g_g_` double prefix on global pointer loads: seven codegen paths
      (`.ai_global_ptr`, `.addr_global_ptr`, `.index_global_ptr`,
      `.post_global`, `.postd_global`, `.ga_ident_global_ptr`,
      `.ga_index_global_ptr`) emitted `mov rax, [rel g_g_name]` for globals
      already spelled `g_*` (nasm: `symbol g_g_p not defined`); all now call
      `strip_g_prefix`. Regression: `global_struct_ptr_index.c2`.
- [x] Member access on a call result (`f()->kind`) returned the raw struct
      address instead of loading the field: `gen_call` never recorded the
      callee's return type/field array, so `.member_expr_base` silently
      no-opped (stale `gen_expr_struct_fields`). Fix: parser stores the
      pointee field array for `struct T *f()` returns (was 0), and
      `gen_call` sets `gen_expr_type`/`gen_expr_struct_fields` from the
      function-return registry after the call. Regression:
      `call_result_member.c2`.
- [x] Assigning a struct array to a struct pointer (`g_p = g_arr;`) memcpy'd
      over the pointer variable itself: `gen_assign` picked the struct-copy
      path from the RHS evaluation type alone (an array of structs decays to
      `TOK_KW_STRUCT`) and never checked the LHS type. Fix: classify the LHS
      first — pointer-typed LHS stores the address as a plain qword.
      Regression: `global_array_to_ptr_assign.c2`.
- [x] Undeclared identifiers in expressions compiled to silent garbage (no
      diagnostic, value reads whatever register held): `.ident`,
      `.index_no_base`, and `gen_addr` not-found paths yielded 0 silently.
      Fix: new `report_undeclared` hard compile error (`undeclared
      identifier 'name'`, exit 1) in all three paths;
      `undeclared_index_no_crash.c2` moved to `faults/undeclared_index.c2`
      expecting the error.

### M1 — Types + first codegen: "LLVM with types and traps" (§19.7)

- [ ] Type checker for scalars, functions, structs, enums, `switch`
      (no ownership yet). Codes: `TYPE-01..04`, `MUT-01..03`, `INIT-01`,
      `CASE-01/02` (on enums), `FMT-01`.
- [ ] LLVM IR text emission for the same subset (§19.4 mapping table):
      checked arithmetic via `llvm.*.with.overflow` + `lc_trap`,
      bounds-checked indexing before GEP, `main` entry, `extern fn`
      declarations, `noalias` for `&mut`.
- [ ] Runtime (`rt.bc` + `rt.h` from one source): `lc_alloc`/`lc_free`
      (trap on OOM), `lc_trap` + trap codes `T-*` (§14.1), buffered output,
      argv access, stack-guard handler (`T-STACK`).
- [ ] `lc run` builds via `llc`/linker and spawns; trap exit status 70 (§14.3).
- [ ] Byte-deterministic `.ll` output; name mangling `module__Type__method`
      with readable type-argument suffixes (§19.4). No hashes, no paths.

### M2 — Ownership: moves + drop elaboration (§9, §19.7)

- [ ] Moves (`MOVE-01..04`), `copy` bounds (§5.6–5.7, `TYPE-05/06`),
      `.clone()`, `Heap<String>`/`Vec`/`cleanup` (§6.6), drop flags (§9.5),
      `MOVE-02` loop moves, re-initialization (§9.7).
- [ ] Moves dataflow over the CFG IR (§19.2); the **event log** (`born`,
      `moved`, `used`, …) is recorded during lowering (§19.3) so the story
      diagnostics fall out.

### M3 — Borrow checker (§10, §19.7)

- [ ] Loans `(place, kind, region)`; liveness-based regions (§10.2, §19.2);
      conflict codes `LOAN-01..03`; reborrowing (§10.5); disjoint fields
      (§10.6); two-phase borrows (§10.7); borrowing from collections (§10.8).

### M4 — Lifetimes: `life` (§11, §19.7)

- [ ] `life` parameters, `life(static)`, elision rules (§11.3), inference +
      region constraints (§19.2); codes `LIFE-01..04`.

### M5 — Diagnostics polish (§16, §19.7)

- [x] Diagnostic model: `code`, `severity` (STOP/WARN/HINT), `title`,
      `summary`, `story[1..5]` steps with roles + `◂ here` trigger, `fixes`
      with `try:`/`or:` (§16.2).
- [x] Renderers: pretty (§16.2 anatomy), `--format=line`, `--format=json`
      (§16.7, stable keys incl. `story[].role` and editor-applicable fixes).
- [x] Ordering by primary location; caps 5 stops / 10 warns + `…and N more
      stops (use --all)` (§16.9); `--strict` (§16.4); `explain <CODE>`
      (§16.8); driver-level codes have lessons.
- [x] Migration hints `NAME-02` for recognized foreign words (§16.11 hook
      point; lexer/parser supply the words).
- [ ] Glyph fallbacks `--ascii` (§16.3): `(1)`/`>`/`<-- here`; color when
      enabled, honoring `--no-color`/`NO_COLOR` (decoration only).
- [ ] Full `explain` corpus: one lesson per code (WHAT/WHY/BAD/GOOD/NOTE/SEE).
- [ ] Story alignment: right-aligned line numbers, trimmed 48-column source,
      60-char labels (§16.2/16.3), other-file steps print `lib/x.src:3:5`.
- [ ] Cascade control (§16.9): type errors suppress ownership analysis in the
      same function; one report per root cause with `also used at …` folding.
- [ ] Every STOP carries ≥1 `try:` fix (§16.1; enforced by tests).

### M6 — `unchecked`, `raw`, FFI, audit (§13, §19.7)

- [ ] The seven powers gate (§13.2): raw deref/arithmetic, `unchecked fn` and
      `extern fn` calls, `reinterpret`, `get_unchecked`, `Heap::from_raw`.
- [ ] Reason rules: mandatory string literal ≥ 12 chars (`UNCK-02`),
      blast-radius warn > 10 lines (`UNCK-03`), calling an `unchecked fn`
      outside a block (`UNCK-04`), `--deny-unchecked` (`UNCK-05`).
- [ ] `audit` lists every site with file/line/reason (§13.6); `audit --json`
      for CI.

### M7 — Standard library, C backend, formatter, fuzzing (§15, §19.7)

- [ ] Prelude: `print`/`println`/`eprintln` (+ `{}`/`{:?}`/`{:.N}`,
      `FMT-01`), `trap`, `assert`, `exit`, `leak`, `drop`, `swap`, `replace`.
- [ ] `String`/`.own()`, `Vec`, `Heap`, `Maybe`/`Has`/`Empty`,
      `Outcome`/`Good`/`Bad`, `str` slices + char-boundary traps (§14.1).
- [ ] Iteration protocol: `fn next(&mut self) -> Maybe<T>` (§6.6, §8.5).
- [ ] C11 backend (`emit-c`, §19.4b): same mapping-table semantics, run
      through the host `cc`; cross-check results against the LLVM path.
- [ ] `lc fmt`: canonical formatter, one style, no options (§19.5) — out of
      scope for harmony-base v0; document divergence.
- [ ] Test strategy (§19.6): accept suite; reject suite — for **every code**,
      ≥3 programs that must be rejected with that exact code; snapshot tests
      incl. `--ascii` and `--format=json`; ASan/UBSan fuzzing of C output with
      no `unchecked` (any sanitizer report = compiler soundness bug);
      differential tests against a reference interpreter.

### Test & fuzz status (continuous)

- [x] Golden fixtures (9) incl. all three formats; byte-exact.
- [x] Driver smoke tests (27); fuzz robustness (24).
- [x] Determinism: binary + all three diagnostic formats.
- [ ] Language accept/reject suites grow per milestone (M1 onward).
- [ ] `assert 1` runtime-trap tests (exit 70, `T-ASSERT`) once `lc run` exists.

### Cross-cutting / docs

- [x] Update `docs/harmony.md` reference where implementation diverges
      (v0.3 rewrite consumed 2026-11-13; source realigned to it).
- [x] Fill `docs/keywords.md` (keywords + builtins + code catalogue).
- [ ] Keep this checklist in sync as items complete.

---

## harmony (self-hosted, later)

- [ ] Rewrite in harmony-base itself once v0 is expressible.
- [ ] Byte-deterministic self-hosting milestone.
