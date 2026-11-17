# The aggressive fuzzer — the rewrite gate

`tests/fuzz2/fuzz.py` is the tool that must run **clean for a sustained
campaign** before the `harmony` rewrite in harmony-base is started. A
compiler that crashes, hangs, or disagrees with itself on *adversarial* input
will poison a self-hosted rewrite: every instability becomes a miscompiled
rewrite.

## Why each engine exists (what it catches that the others cannot)

| Engine | Class it owns |
|---|---|
| `specials` | Adversarial *shapes* hand-derived from the real failure modes found so far: parser-depth walls, name-length truncation, lexical boundaries, unbalanced structure, unicode, self-referential types. Deterministic — a fixed regression list. |
| `gen` | Grammar-sampled *valid-ish* programs. Reaches deep checker/backend states (generic nests, `unchecked` + raw pointers, switch exhaustiveness, casts) that byte mutators never produce because they destroy syntax first. **The sampler tracks the names it declares** so references resolve; that is what makes it the engine that reaches the most compiler code (see below). |
| `mut` | Token-level mutation of the **real test corpus** (the `tests/harmony` suite, ~150 programs): splice, span-duplicate, adversarial-token insert, identifier swap, overlong token. Walks real syntax much farther than byte flips. |
| `afl` | AFL++ dumb-mode (the binary is FASM-built: no compile-time instrumentation exists; QEMU/FRIDA absent in this environment). Beats the channel for *corruption* the structured engines won't emit (bytes inside cooked strings, radical splices). Dumb mode has no coverage feedback, so the queue stays at the seed set — its value is raw execution volume, and the engine reports its real exec count so a broken launch cannot read as "clean". |
| `valgrind` | The only oracle for uninitialised reads / invalid heap access (this build class showed up during the design probing). Runs `check` and `emit-llvm` over a corpus+generated sample; too slow for the hot loop. |

**Every engine must prove it ran.** A fuzzer that silently does nothing
reports "0 findings" and is worse than no fuzzer, because it manufactures
confidence. The valgrind engine once passed a nonexistent flag
(`--exit-code-first`) and spent an unknown number of campaigns reporting a
false clean; it now counts completed runs and errors out at zero, and the AFL
engine reports its execution count. Any new engine needs the same property.

## Which engine actually reaches the compiler

Measured with callgrind (function-level attribution, resolved through the
binary's symbol table), 25 programs per engine, over the same `check` +
`emit-llvm` path the fuzzer uses:

| Engine | check-clean | distinct compiler functions reached |
|---|---|---|
| `gen` (current) | **25/25** | **316** |
| `gen` (previous) | 2/25 | 227 |
| `mut` | 28/30 | 60 |

So `gen` is the engine that matters, and the number that matters is *how many
programs reach the checker at all*: the previous sampler emitted dangling
references on purpose (`Maybe-51`, `methods M0` with no `M0` declared,
`let v = v;`), so 95% of programs died in `check` with NAME-01/SYN-05/TYPE-02
before reaching the semantic stage. The 115 functions the current sampler
reaches and the old one did not are exactly that stage
(`ck_expr_call`, `ck_instantiate_type`, `ck_enum_construct_ty`, ...).

This is a property of the *sampler*, so it can silently regress.
`tests/harmony/coverage.sh` measures it on every `make test` and fails if the
count drops below a floor — the check that a weaker sampler is caught rather
than shipped.

**Deliberately broken input still has an owner.** The sampler now emits
resolvable programs, but malformed *bytes* and token damage are still covered
— by `mut` (token splicing) and `afl` (byte corruption), which is what those
engines are for. The sampler owns *structure*, not entropy.

## The five oracles (a crash alone is a weak bar for a compiler)

- **O1 liveness** — every exit is defined and in the driver's vocabulary
  (0 ok, 1 stop, 2 usage); nothing times out. "Crash" and "large exit value"
  are distinguished: the driver reports a signal death on stderr, because
  `run` forwards `main`'s value mod 256 and 241 is a legal result (an early
  oracle flagged those; the driver now says "killed by signal N", which makes
  the two unambiguous).
- **O2 agreement** — `check` rc==0 ⟹ `emit-llvm` rc==0 with non-empty output;
  `check` rc!=0 ⟹ emit refuses. The two stages must agree on every input.
- **O3 determinism** — two `emit-llvm` runs are byte-identical (the rewrite's
  milestone requirement, checked on every clean program).
- **O4 opt-level** — programs that run agree across `-O0`/`-O2`/`-O3`
  (miscompiles surface as differing exit codes). Only applied to programs with
  an empty trusted surface (§13.6): with an `unchecked` site, UB may legally
  differ per level — e.g. a null store is folded to `unreachable` at `-O2`.
- **O5 memory** — valgrind memcheck clean (sampled).

## Findings → tests

Any violation is **shrunk** (line-dropping, then token-span delta debugging,
keeping the failure class stable) into `tests/fuzz2/findings/` with the
failing oracle and a before/after copy. Each finding then becomes a permanent
regression case in `tests/harmony/error-handling/` (or `codegen/` for
miscompile-class) — the corpus grows monotonically.

## Running

```sh
make test-fuzz2                      # the fast smoke gate (specials, no shrink)
make fuzz2-deep                      # specials + gen + mut, 1000 iterations
python3 tests/fuzz2/fuzz.py --engines gen,mut --iterations 2000 \
       --run-generated --seed 1       # full O4 coverage on a fixed seed
python3 tests/fuzz2/fuzz.py --engines afl --afl-seconds 300
python3 tests/fuzz2/fuzz.py --engines valgrind --vg-sample 30
```

Historical record (kept so a regression is noticeable):
- 2026-11: designing the fuzzer by direct probing found 3 real bugs *before
  the first automated run*: a parser stack-overflow SIGSEGV at ~10k nesting,
  a silent 512-byte name-truncation that made distinct generic types collide,
  and quadratic generic instantiation (27s → 0.13s at depth 300). All fixed
  in `39ce687`; the `specials` engine encodes them.
- 2026-11: the first campaign run found four more, each now a regression:
  - a 13-digit integer literal overflowed a `char tmp[12]` in the emitters'
    decimal writer, so `check` accepted the program and `emit` died with no
    diagnostic (O2 agreement). `tests/harmony/codegen/fuzz-fixes.harmony`.
  - nested generic type resolution was exponential in the nesting depth (a
    15-level `Box<Box<...>> = 1` never finished); type resolution is memoized
    per AST node. `generic-deep-mismatch-prompt` + `fuzz-fixes`.
  - concurrent `run` invocations clobbered one another: the driver used fixed
    `/tmp/harmony-base.bin` paths, so a parallel build truncated the binary
    another had just linked (exit 127). Temp paths are per-process now.
    `tests/harmony/fuzz.sh` → `concurrent-run-isolation`.
  - the runtime labeled *every* SIGSEGV "stack exhausted", hiding real
    `unchecked` bugs; the handler now reads `siginfo_t`/`ucontext` and only
    reports `T-STACK` for a fault in the guard page, re-raising otherwise.
- 2026-11: two oracle *false positives* fixed (they were the fuzzer's bug, not
  the compiler's): exit values ≥128 are legitimate (`main` mod 256), and O4
  must skip `unchecked` programs because their UB may differ per opt level.
- 2026-11: rewriting the grammar sampler to emit *resolvable* programs (it
  used to invent dangling names) exposed three real checker gaps, all the
  same shape — the compiler knew the expected type but did not pass it down:
  - an **assignment** did not supply the place's type, so `v = Empty;` was
    NAME-01 "no `Empty` in scope" though `v: Maybe<i64>`;
  - a **call argument** did not supply the parameter's type, so
    `g(9, Empty)` failed though `g` takes a `Maybe<i32>`;
  - the same in a **generic call**, `g<i32>(9, Empty)`.
  All three now pass the expected type as the hint (§8.5).
  Regression: `tests/harmony/codegen/expected-type-hint.harmony`.
- 2026-11: a method's *bare* name was also bound as a global symbol, so two
  types could not declare a method with the same name (`methods A { fn m }`
  then `methods B { fn m }` was NAME-03, though the backend mangles them per
  receiver). Regression:
  `tests/harmony/codegen/method-name-collision.harmony`.
- 2026-11: **sustained-campaign baseline** (the rewrite gate). Full sweep,
  2 cores, seed 4240783976, 711s wall:
  `--engines gen,mut,specials,valgrind,afl --iterations 4000 --run-generated
  --vg-sample 80 --afl-seconds 120`
  → 4,000 generated + 4,000 mutants + 27 specials, 160 valgrind runs, 81,604
  AFL executions, **0 findings**. Re-run this (and vary `--seed`) before
  trusting any later change; a regression here means the rewrite would
  inherit an unstable front end.
- 2026-11: the grammar sampler was rewritten to emit *resolvable* programs
  (it used to invent dangling names). Measured with callgrind, the sampler
  now reaches **316** distinct compiler functions against 227 before, and
  25/25 programs pass `check` against 2/25. The 115 newly-reached
  functions are exactly the semantic stage (`ck_expr_call`,
  `ck_instantiate_type`, `ck_enum_construct_ty`, ...). Four real checker
  bugs fell out of it — the expected type was known but not passed down for
  an assignment, a call argument, and a generic call, and a method's bare
  name was bound globally so two types could not share a method name.
  `tests/harmony/coverage.sh` guards the property on every `make test`.
