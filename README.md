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
  branch (or when an existing `VERSION` already declares beta, so a 1.0 line
  can be prepared before its branch is cut), `dev` otherwise.
- **NUMBER** — commits since the last release tag.
- **sha** — the short commit sha of HEAD, as SemVer build metadata.

The `1.0.0` line is open in beta while the language is still being finished;
the final `1.0.0` release comes only when it is fully implemented. The first
seed-native final release is `1.0.0` (there is no `0.4.0`).

```bash
make version            # regenerate the VERSION file
./build/harmony --version
```

## Toolchain (debian)
```bash
sudo apt update
sudo apt install make gcc clang llvm-dev file liblld-dev python3 qemu-system-x86 python-is-python3 afl++ linux-perf xxd nano gdb valgrind strace git ripgrep llvm -y
# nasm and fasm are only needed to rebuild the archived legacy/bootstrap tree
```
Also install (for fuzzing tests): https://github.com/google/honggfuzz

## Layout

| Path | What it is |
|---|---|
| `docs/harmony.md` | The language design / reference. |
| `docs/changelog.md` | Version history and the vocabulary map (moved out of `harmony.md` §1). |
| `docs/c2x-seed.md` | The retired stage-0 compiler (x86_64 assembly); archived with the legacy tree. |
| `docs/keywords.md` | Keyword / builtin reference. |
| `bootstrap/seed/` | Checksum and provenance for the stage-0 seed; the binary is downloaded from a release. |
| `library/runtime/` | The freestanding runtime the compiler links in. |
| `harmony/` | The self-hosted compiler (`*.hr`); phase plan in `roadmap/harmony`. |
| `library/core/`, `library/alloc/`, `library/std/` | Standard library for the final language. `core` (arena, `Vec`, `String`) is started. |
| `tests/` | Test suites and fuzzing. |
| `tests/env.sh`, `tests/env.py` | Shared harness config (`HARMONY`, `HC`, `HB`); no legacy lane remains. |
| `docs/bootstrap-retirement.md` | Legacy freeze, release and repository-protection follow-ups. |
| `roadmap/` | Milestone checklists. |
| `todo.md` | Detailed implementation checklist. |

The legacy `c2x-seed` / `harmony-base` toolchain, its golden oracle outputs and
its two-lane harness are preserved on the `legacy/bootstrap` branch, tagged
`legacy/bootstrap-final`. They are intentionally absent from this tree.

## Build

```bash
make               # build build/harmony from the frozen stage-0 seed
make verify-seed   # check the seed binary's sha256
make test          # full single-lane suite (compiler under test: build/harmony)
make test-final    # the compiler's own tests (tests/harmony-final)
make test-fuzz     # aggressive/fuzz driver tests
make test-fuzz2    # the fast adversarial fuzz smoke gate
make qualify-seed  # assert stage1 == stage2 == stage3 byte-for-byte
make version       # regenerate the VERSION stamp
make clean
```

`HARMONY`, `HC` and `HB` (settable as environment variables) all default to
`build/harmony`. There is no second compiler to select: suites that used to
compare against the legacy oracle were retired with it, and now check
determinism against this binary. Only explicit `SKIP`s are allowed for features
that are not implemented yet; every other failure fails the suite.

`build/harmony` is rebuilt from a byte-identical stage-1 seed, downloaded from
the [`stage0-v1` release](https://github.com/CreitinGameplays/harmony/releases/tag/stage0-v1)
into gitignored `build/seed/` and verified against `bootstrap/seed/SHA256SUMS`
before it runs. For offline builds, point `SEED_BIN` at a local copy (and
`SEED_URL` at a mirror if needed). The latest compiler release is always the
next seed. The seed needs the LLVM/LLD runtime libraries that `llvm-config`
points at (LLVM 21 in the CI image).

## Usage (docs/harmony.md §19.5)

```bash
harmony check main.harmony              # analyses only, no codegen
harmony --dump-ast check main.harmony   # print the parse tree
harmony --dump-tokens main.harmony     # print the token stream
harmony --version                      # SemVer 2.0.0 stamp from VERSION
harmony build main.harmony -o hello    # compile to an executable
harmony run main.harmony               # build and run
harmony emit-llvm main.harmony         # print the generated LLVM IR
harmony emit-c main.harmony            # C11 backend (not implemented yet)
harmony explain MOVE-01                # long-form lesson for a code
harmony audit                          # list every `unchecked` site
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
