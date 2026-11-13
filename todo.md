# Harmony — TODO

Legend: [ ] - Not implemented; [/] - Partially implemented; [x] - Fully implemented.
Update todo.md accordingly.

Status legend: `[ ]` not started · `[/]` partial · `[x]` done.

---

## harmony-base — detailed implementation checklist

`src/harmony-base/*.c2` — the first Harmony compiler, written in c2x-seed.
Target: the v0 core feature set in `docs/harmony.md` §2, §4, §7–22.
Output extension: `.harmony`. Milestone: byte-deterministic build.

### P0 — Toolchain, layout, skeleton, tests

- [x] `Makefile` rules: `harmony-base` (build compiler), `test`, `test-seed`,
      `test-fuzz`, `clean`; `build.sh` (c2x-seed) is a prereq of the compiler.
- [/] `src/harmony-base/` file layout (each file < ~1500 lines; split aggressively):
  - [x] `common.c2` — shared declarations (types + cross-module prototypes).
  - [x] `main.c2` — driver: arg parsing, pipeline wiring, exit codes.
  - [x] `source.c2` — source manager: file load, line index, byte offset→line/col.
  - [x] `diag.c2` — report builder + text renderer (P0 subset).
  - [x] `util.c2` — arena allocator, string helpers, out/err helpers.
  - [x] `ast.c2` — AST node definitions + arena-backed resizable child lists.
  - [/] `lexer.c2` — token model + P0 EOF-only stub.
  - [/] `parser.c2` — recursive-descent parser (P0 stub).
  - [ ] `resolve.c2` — names/IDs → HIR.
  - [ ] `types.c2` — type checker + copy rules.
  - [ ] `hir.c2`, `mir.c2` — IR types and builders.
  - [ ] `exhaust.c2` — pattern-matrix exhaustiveness.
  - [ ] `dataflow.c2` — init + move analysis.
  - [ ] `borrow.c2` — loans + regions/`life`.
  - [ ] `drops.c2` — drop insertion.
  - [ ] `lower_llvm.c2` — LLVM IR backend (**priority**).
  - [ ] `lower_c.c2` — C11 backend (secondary).
  - [ ] `runtime.ll` / `runtime.c` — the ~400-line runtime.
- [/] Driver subcommands: `build`, `check`, `run`, `--emit=c|ir|asm`,
      `--explain`, `--report=json|seams`, `--strict`, `--forbid=`, `--allow=`,
      `--max-faults=`. (`build`/`check`/`run` + all flags parse; backends still
      return `70`, and `--explain` serves the driver/`compiler.internal` pages.)
- [x] Exit codes: `0` ok, `1` compile fault, `2` usage, `70` `compiler.internal`, `101` runtime abort.
- [x] Deterministic build: no timestamps/PIDs/paths in output; stable symbol
      names. Fixed the c2x-seed PID-in-`FILE`-symbol bug (see
      `docs/c2x-seed.md`); guarded by `tests/harmony/determinism.sh`.
- [x] Test harness: golden fixtures under `tests/harmony/golden/`; diff stdout +
      exit code byte for byte via `tests/harmony/golden.sh`.
- [x] `tests/harmony/run.sh` + `tests/harmony/fuzz.sh`; registered in Makefile.
- [x] `tests/c2x-seed/run.sh` + `tests/c2x-seed/determinism.sh` — c2x-seed
      regression corpus (`make test-seed`).

### P0.5 — c2x-seed fixes required to build harmony-base

Twelve c2x-seed defects were found and fixed while bootstrapping (see
`docs/c2x-seed.md` "Recent Bug Fixes"):

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

### P1 — Diagnostics + source spans

- [x] Span type `{file, start, end, role}`; primary + secondary span slots.
- [/] Report model: `id`, `severity`, `summary`, `spans[]`, `rule`, `got`,
      `want`, `note`, `why`, `from`, `fix`, `explain`. Single `fix`/`note`
      today; `fixes[]`/`notes[]` lists and fix-it application land in P14.
- [/] Text renderer (§23.3): `<severity> · <id>  path:line:col` header, source
      lines (≤6, §23.4), labelled lines, `see` footer. The box corners
      (`╭─`/`├`/`╰`), gutter, and `◀────` markers are still to come.
- [x] Label set (closed): `rule got want note why from fix see`; 5-char column.
- [x] Report ordering by primary span ascending; `--max-faults` cap (default 50,
      0 = see all) + trailing `… N more faults` summary.
- [x] Severity words: `fault` (exit 1), `warn` (continue), `runtime fault` (abort 101).
- [/] Stable `area.slug` IDs (no E-codes); reports always carry a rule line +
      ≥1 span when one exists. The full `<area>.<slug>` catalogue grows per phase.
- [x] `--explain <id>` long-form (driver/`compiler.internal` pages so far);
      `--allow=<id,id>` (warnings only) and `--forbid=unchecked|keep`.
- [x] JSON twin `--report=json` (one object per line, stable keys §23.10).
- [ ] Fix-its: `applicability=machine|manual`, `--fix` applies machine edits only.
- [x] `compiler.internal` shape: snippet + "this is a bug" explain page.

### P2 — Lexer (§7)

- [ ] UTF-8 source ingest; nested `/* */` and `//` comments.
- [ ] Identifiers `(letter|_)(letter|digit|_)*`; reserved keywords (Appendix D).
- [ ] Integer literals: dec/hex/bin/oct, `_` separators, suffixes `u8..i128`.
- [ ] Float literals: `.` or exponent required; `f32`/`f64` suffix.
- [ ] `bool` literals `true`/`false`.
- [ ] `char` literals incl. `\u{...}`; one scalar value.
- [ ] String literals incl. escapes `\n \r \t \\ \" \' \0 \u{...}`; length-delimited.
- [ ] Operators: `and or not`, `band bor bxor bnot shl shr`, `->`, `::`, `+=`
      family, `..`-free; `<< >> & | ^ ~`.
- [ ] No automatic semicolon insertion; missing `;` → `syntax.missing-semicolon`
      with a fix-it.
- [ ] Position tracking: `tok_line`, `tok_col`, byte offsets.

### P3 — AST + Parser (Appendix A)

- [ ] AST arena; node IDs; preserve spans on every node.
- [ ] Top-level: `fn`, `struct`, `copy struct`, `enum`, `copy enum`, `methods`,
      `const`, `extern fn`, `unchecked fn`, `unchecked extern fn`.
- [ ] Statements: `let` (with/without `mut`, with/without type/init), assignment
      (statement not expression), `if/else if/else`, `while`, C-style `for`,
      range `for (x : expr)`, `switch`, `break`, `continue`, `return`, expression
      statement, `unchecked` block (+ optional reason).
- [ ] Declarations: struct fields `name: Type;`; enums variants `V(p1,p2),`;
      lifetimes `life a` (declare) / `life(a)` (use).
- [ ] Expressions + precedence (Appendix B); struct literal `Type { .x = e, }`;
      enum construction `Type::Variant(...)`; `switch` patterns.
- [ ] Type syntax: primitives, `[T; N]`, `[T]`, `&T`, `&mut T`,
      `&life(a) T`, `Vec<T>`, `Text`, `str`, `Heap<T>`, `Maybe<T>`, `Raw<T>`,
      `()`; generics `<T, life a>`.
- [ ] Assignment-in-condition is a parse fault
      (`syntax.assignment-is-not-an-expression`).
- [ ] No trailing-expression return: `a + 1` as a body statement →
      `syntax.expected-return`.
- [ ] `self` only inside `methods`; `Type::name` assoc fns.
- [ ] Recovery: parse faults are counted; compilation aborts after parse.

### P4 — Name resolution (§24.8)

- [ ] Scope stack: blocks, params, generics, `life`s, `methods` `self`.
- [ ] Resolve value names, type names, variant names, field names, fn names.
- [ ] `name.not-found` with "did you mean" fix; `name.duplicate`.
- [ ] `methods` blocks merge per type/impl within a file (no modules in v0).
- [ ] Build HIR with resolved IDs + types placeholders.

### P5 — Type checker + copy rules (§8, §10, §11, §12, §26.3)

- [ ] Primitive sizes/signedness (`uN`/`iN`/`fN`/`bool`/`char`/`()`/`!`).
- [ ] `type.mismatch` (no implicit conversions, not even widening).
- [ ] `type.not-a-bool` for conditions (`if (1)` faults).
- [ ] `!` coerces to any type (return/panic/break/continue).
- [ ] No subtyping among numbers; `as`, `narrow`, `wrap` are named ops.
- [ ] Generics monomorphization; only bound is `<T: copy>`; no traits/vtables.
- [ ] `copy` legality: `type.not-copy`, `copy.too-large` (>128B),
      `copy.field-not-copy`; built-in `Maybe<T>` copies iff `T: copy`.
- [ ] Struct field existence/arity; `init.missing-field` (list missing).
- [ ] Enum variant arity; payload positional typing.
- [ ] `switch` subject domain: int/bool/char/`&str`/enum; `default` required on
      open domains.
- [ ] String equality/ordering rules; `str` vs `Text` comparison faults.
- [ ] Structural `==` generation for `copy struct`/`copy enum`; no `==` on owning
      types; `Heap<T>` no `==`.
- [ ] `drop` hook legality: `drop.on-copy-type`, no panic in `drop`.
- [ ] `unchecked` type rules: `Raw<T>` only in `unchecked`/`unchecked fn`
      (`unchecked.in-safe-signature`, `unchecked.raw-escapes`).
- [ ] Float rules: `NaN != NaN`, no default ordering.
- [ ] Recursive types via indirection; `type.infinite-size` otherwise.

### P6 — HIR → MIR lowering (§24.1, §25.1)

- [ ] MIR: basic-block CFG over **places** and temporaries.
- [ ] Place = root local + projection path (`.field`, `[index]`, `*deref`).
- [ ] Lower: assigns, rvalue temp creation, calls, `switch` → tagged branches.
- [ ] Keep source spans on MIR statements for `use`/`origin` roles in reports.

### P7 — Exhaustiveness (§24.7)

- [ ] Pattern matrix (one column per payload, one row per arm, `default` wildcard).
- [ ] Usefulness algorithm → coverage + witness.
- [ ] `switch.not-exhaustive` with witness (partial witnesses like `Rect(_, 0.0)`).
- [ ] `switch.unreachable-arm` warning.
- [ ] Two-fix output: add arm, or add `default` (note it hides future variants).

### P8 — Dataflow: init + moves (§24.2)

- [ ] Lattice per place: `Init | Moved | Uninit`; must-analysis over CFG.
- [ ] Join = `Init` only if all incoming paths `Init`.
- [ ] `init.read-before-write` (never written) vs `move.maybe-moved` (given away).
- [ ] `move.after-handoff` (classic pair: handed over here … used again here).
- [ ] `move.partial` for field move; `take(place)` → field `Moved`, container `Partial`.
- [ ] `switch (owned)` sets subject `Moved` after switch.
- [ ] Shadowing creates a new place; old binding unaffected.
- [ ] Re-arming a moved var by assignment restores `Init`.
- [ ] Assignment to `Init` owning var destroys old value first.

### P9 — Borrow checker + `life` (§16, §17, §24.3–24.5)

- [ ] Loan = `{place, shared|exclusive, region}`.
- [ ] Liveness: backwards pass; loan dies at last use of derived refs (§16.2).
- [ ] Conflict table (read/write/`&`/`&mut` vs ancestor loans); sibling places
      disjoint.
- [ ] `borrow.conflict` with three markers (origin / needs-mut / last-use) + fixes.
- [ ] `borrow.while-iterating` for container mutation during `for`.
- [ ] Field-precision: `&p.x` + `&mut p.y` coexist.
- [ ] Allocation-identity loans for deref paths (list-walk exception §24.5).
- [ ] Reborrow child regions for `&mut` calls (allow repeated `bump(&mut x)`).
- [ ] Region constraint graph + transitive closure of outlives edges.
- [ ] Elision E1–E4; `life.cannot-elide` naming the parameter to annotate.
- [ ] Dangling return → `life.outlives`.
- [ ] `life.temporary`: temporary cannot be borrowed across a statement.
- [ ] Subtyping: `&` covariant, `&mut` invariant in region, `Heap/Vec/Text`
      invariant; `life(static)` shortens freely.
- [ ] Value built-ins field-level summaries (`v.len` read, `push` writes all).

### P10 — Drop insertion (§21, §24.6)

- [ ] At every scope exit (fall/return/break/continue): destroy `Init` places in
      reverse declaration order; params after locals.
- [ ] `switch` arm bindings dropped at arm end.
- [ ] `take`n field not destroyed by container; new owner destroys it.
- [ ] Returned value moved out before epilogue (not destroyed).
- [ ] User `drop` method runs before fields; fields in declaration order.
- [ ] No landing pads (v0 aborts) — panics do not run destructors.
- [ ] `discard(x)` → destroy immediately.

### P11 — LLVM backend (**priority**) (§25)

- [ ] LLVM IR type mapping for all v0 types.
- [ ] Function ABI; `main` entry; `extern fn` C ABI (no varargs in v0).
- [ ] Codegen for expressions, control flow, `switch` (tag dispatch, no fallthrough).
- [ ] Place lowering to `alloca`/`GEP`; `Heap<T>` = unique pointer; `Text`/`Vec`
      = 3-word structs.
- [ ] Checked arithmetic/`[]` calls into runtime (`rt_add_*`, `rt_index`, …).
- [ ] Debug poisoning of moved-from memory; `0xAA` fresh alloc fill.
- [ ] `restrict`/noalias for `&mut` params; release removes proven-redundant checks
      without changing semantics.
- [ ] Monomorphization of generics.
- [ ] Deterministic IR: stable symbol/type names, no hashes/timestamps.
- [ ] `--emit=ir` and assembling/linking to executable.

### P12 — Runtime library (§26.5)

- [ ] `rt_alloc(size, align)` → `panic.out-of-memory` on failure.
- [ ] `rt_free(ptr)`.
- [ ] `rt_index(v, i, file, line)` → `panic.bounds`.
- [ ] `rt_add_i32`/`rt_mul_i64`/… checked arithmetic → `panic.overflow`.
- [ ] `rt_div`/`rt_rem` → `panic.divide-by-zero`.
- [ ] `rt_shift` → `panic.shift-too-large`.
- [ ] `rt_abort(id, msg, file, line)` → runtime-fault text, flush, abort (101).
- [ ] `rt_leak(x)` records leak; debug summary at exit.
- [ ] Formatting helpers for `{}`, `{:?}`, `{:.N}`; compile-time placeholder
      parsing, `syntax.format-arity` on mismatch.
- [ ] `panic.not-a-char-boundary` for `slice`/`truncate`/`char_at`.
- [ ] `own`/`copy`/`append`/`truncate`/`slice`/`find`/`char_at` (`Text`).
- [ ] `Vec` methods: `new push pop length get get_mut slice slice_mut clear
      truncate insert remove reserve`.
- [ ] `take(*b)` for `Heap`; `keep`, `raw`, `null<T>` builtins.
- [ ] Type `drop` glue generation from type definitions (recursive via `Heap`).

### P13 — C11 backend (secondary) (§25.2)

- [ ] Straightforward mapping table §25.2; `rt_*` calls; `switch` tag dispatch.
- [ ] `--emit=c` output; compile + run as cross-check against LLVM backend.
- [ ] Byte-for-byte deterministic C output.

### P14 — Reporting polish (§23)

- [ ] `--explain <id>` corpus for every ID.
- [ ] `--report=seams`: list `unchecked` blocks/fns + `keep` with file/line/reason.
- [ ] `--strict` requires reason on every `unchecked` block.
- [ ] `warn · seam.no-reason` lint.
- [ ] `--forbid=unchecked` / `--forbid=keep`.
- [ ] JSON roles: `primary|origin|use|conflict|note`.
- [ ] Cascading-fault suppression; one cause one report.

### P15 — Tests, fuzzing, determinism (§24.9, AGENTS.md)

- [ ] Positive fixtures per feature (FizzBuzz, stack machine, list walk, checksum,
      `Own`/`Text` conversions, vec slice).
- [ ] Negative fixtures asserting exact `<area>.<slug>` IDs + spans.
- [ ] Report-shape tests: every report has a rule line and ≥1 span.
- [ ] Runtime-fault tests asserting abort + codes (`101`).
- [ ] `tests/aggressive-fuzz/`: random + mutational fuzzing of the parser/checker
      (no crashes, no hangs, always a fault or a verdict).
- [ ] Determinism test: build same input twice → identical bytes.
- [ ] Bootstrap smoke test: `harmony-base` compiles a representative corpus.
- [ ] Register all suites in Makefile (`test-harmony-base`, `test-harmony-base-fuzz`).

### Cross-cutting / docs

- [ ] Update `docs/harmony.md` reference where implementation diverges.
- [ ] Fill `docs/keywords.md` (keywords + builtins table, currently empty).
- [ ] Keep this checklist in sync as items complete.

---

## harmony (self-hosted, later)

- [ ] Rewrite in harmony-base itself once v0 is expressible (§25.5).
- [ ] Byte-deterministic self-hosting milestone.
