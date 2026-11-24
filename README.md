<p align="center">
  <img src="logo/banaxe.png" alt="Logo" width="100"/>
</p>
<h1 align="center">Harmony</h1>

Harmony is a small, statically-typed, **GC-free** systems language with
value semantics, one owner per value, checked borrows, explicit lifetimes
(`life`), and a single auditable escape hatch (`unchecked`). Source files use
the `.harmony` (or `.hr`) extension.

The design lives in [`docs/harmony.md`](docs/harmony.md). This repository is a
working compiler for it.

## Versioning

[Semantic Versioning 2.0.0](https://semver.org/), with **rolling support
only**: no bugfix backports to previous branches. The current version is in
the root `VERSION` file:

```
MAJOR.MINOR.PATCH-dev|beta|stable.NUMBER+<short-commit-sha>
```

It is **auto-regenerated** by `tools/version.sh` (run by `make version`, and
by the build), never hand-edited:

- **base** — `MAJOR.MINOR.PATCH`. Preserved from the existing file, except on
  a release branch (`1.0`, `1.1`, ...) where the branch name gives the
  major/minor.
- **channel** — `stable` when HEAD carries a release tag, `beta` on a release
  branch, `dev` otherwise.
- **NUMBER** — commits since the last release tag.
- **sha** — the short commit sha of HEAD, as SemVer build metadata.

`1.0` is reserved: it comes only when the final `harmony` language is fully
implemented.

```bash
make version            # regenerate the VERSION file
./build/harmony-base --version
```

## Toolchain (debian)
```bash
sudo apt update
sudo apt install make gcc clang llvm-dev file liblld-dev python3 qemu-system-x86 python-is-python3 afl++ linux-perf xxd nano gdb valgrind strace nasm fasm git ripgrep llvm -y
```
Also install (for fuzzing tests): https://github.com/google/honggfuzz

## Layout

| Path | What it is |
|---|---|
| `docs/harmony.md` | The language design / reference. |
| `docs/c2x-seed.md` | The bootstrap compiler (stage 0), written in x86_64 assembly. |
| `docs/keywords.md` | Keyword / builtin reference. |
| `bootstrap/c2x-seed/` | Stage-0 compiler in flat-assembler (FASM) assembly (`build.sh` builds it). |
| `bootstrap/c2x-seed-nasm/` | Pre-migration NASM sources (reference only). |
| `bootstrap/tools/` | Migration helpers (e.g. `nasm_to_fasm.py`). |
| `bootstrap/harmony-base/` | First Harmony compiler, written in c2x-seed. |
| `library/runtime/` | The freestanding runtime `harmony-base` links in. |
| `harmony/` | Self-hosted rewrite (`*.hr`); phase plan in `roadmap/harmony`. |
| `library/core/`, `library/alloc/`, `library/std/` | Standard library for the final language. `core` (arena, `Vec`, `String`) is started. |
| `tests/` | Test suites and fuzzing. |
| `tests/env.sh`, `tests/env.py` | Shared harness config for the two-lane bootstrap burn-in (`HARMONY`, `HC`, `ORACLE`). |
| `tests/golden/v0.3.3/` | Legacy oracle outputs frozen before bootstrap retirement; checked by `make verify-goldens`. |
| `tools/capture-goldens.py` | Capture / verify those goldens from the legacy compiler. |
| `roadmap/` | Milestone checklists. |
| `todo.md` | Detailed implementation checklist. |

## Build

```bash
bash build.sh      # build c2x-seed (stage 0) -> build/c2x-seed
make               # build the harmony-base compiler -> build/harmony-base
make test          # seed corpus + driver + golden fixtures + determinism + lisp
make test-seed     # c2x-seed regression corpus + determinism only
make test-fuzz     # aggressive/fuzz tests for the harmony-base driver
make test-lisp     # the harmony-base LISP interpreter suite
make test-final    # the self-hosted compiler's library/ tests (tests/harmony-final)
make lisp          # run the LISP interpreter demo (a multi-module program)
make clean

# Bootstrap-retirement burn-in (Phase 0-1: additive, nothing removed yet)
make test-v1        # full suite driven by build/harmony instead of harmony-base
make qualify-seed   # assert stage1 == stage2 == stage3 byte-for-byte
make goldens        # capture legacy oracle outputs into tests/golden/v0.3.3/
make verify-goldens # re-capture into a temp dir and diff (machine-independent)
```

Test-harness knobs (also settable as environment variables): `HARMONY` selects
the compiler under test for compatibility suites (default: legacy
`build/harmony-base`), `HC` selects the self-hosted compiler used by the v1 and
differential suites (default: `build/harmony`), and `ORACLE` selects the legacy
reference compiler for differential suites (default: `build/harmony-base`).
Only explicit `SKIP`s are allowed for v1 features that are not implemented yet;
every other v1 failure fails the lane.

`harmony-base` is bootstrapped with `c2x-seed`; `c2x-seed` is bootstrapped with
`fasm` + `ld` and needs no libc.

## Usage (docs/harmony.md §19.5)

```bash
harmony-base check main.harmony              # analyses only, no codegen
harmony-base check --dump-ast main.harmony   # print the parse tree (M0)
harmony-base --dump-tokens main.harmony      # print the token stream (differential oracle)
harmony-base --version                       # SemVer 2.0.0 stamp from VERSION
harmony-base build main.harmony -o hello     # compile to an executable
harmony-base run main.harmony                # build and run
harmony-base emit-llvm main.harmony           # print the generated LLVM IR
harmony-base emit-c main.harmony             # print the generated C (secondary)
harmony-base explain MOVE-01                 # long-form lesson for a code
harmony-base audit                           # list every `unchecked` site
# flags: --format=pretty|line|json  --all  --strict  --deny-unchecked
#        --no-color  --ascii  -o <out>
```

Diagnostics tell the story of the value (`docs/harmony.md` §16): a numbered
timeline, plain English, always a fix, stable `AREA-NN` codes. Exit codes:
`0` ok, `1` a STOP (or WARN under `--strict`), `2` usage/IO error.

The primary backend is **LLVM IR** (§19.4); the C11 backend (§19.4b) is the
portable secondary, used as a cross-check.

Milestone: `harmony` is **byte deterministic** — the same input always produces
identical output bytes.
