# Harmony

Harmony is a small, statically-typed, **GC-free** systems language with
value semantics, one owner per value, checked borrows, explicit lifetimes
(`life`), and a single auditable escape hatch (`unchecked`). Source files use
the `.harmony` extension.

The design lives in [`docs/harmony.md`](docs/harmony.md). This repository is a
working compiler for it.

## Layout

| Path | What it is |
|---|---|
| `docs/harmony.md` | The language design / reference. |
| `docs/c2x-seed.md` | The bootstrap compiler (stage 0), written in x86_64 assembly. |
| `docs/keywords.md` | Keyword / builtin reference. |
| `src/c2x-seed/` | Stage-0 compiler in NASM assembly (`build.sh` builds it). |
| `src/harmony-base/` | First Harmony compiler, written in c2x-seed. |
| `src/harmony/` | Self-hosted rewrite (later). |
| `tests/` | Test suites and fuzzing. |
| `roadmap/` | Milestone checklists. |
| `todo.md` | Detailed implementation checklist. |

## Build

```bash
bash build.sh      # build c2x-seed (stage 0) -> build/c2x-seed
make               # build the harmony-base compiler -> build/harmony-base
make test          # seed corpus + driver + golden fixtures + determinism
make test-seed     # c2x-seed regression corpus + determinism only
make test-fuzz     # aggressive/fuzz tests for the harmony-base driver
make clean
```

`harmony-base` is bootstrapped with `c2x-seed`; `c2x-seed` is bootstrapped with
`nasm` + `ld` and needs no libc.

## Usage (docs/harmony.md §19.5)

```bash
harmony-base check main.harmony              # analyses only, no codegen
harmony-base build main.harmony -o hello     # compile to an executable
harmony-base run main.harmony                # build and run
harmony-base emit-c main.harmony             # print the generated C
harmony-base explain MOVE-01                 # long-form lesson for a code
harmony-base audit                           # list every `unchecked` site
# flags: --format=pretty|line|json  --all  --strict  --deny-unchecked
#        --no-color  --ascii  -o <out>
```

Diagnostics tell the story of the value (`docs/harmony.md` §16): a numbered
timeline, plain English, always a fix, stable `AREA-NN` codes. Exit codes:
`0` ok, `1` a STOP (or WARN under `--strict`), `2` usage/IO error.

Milestone: `harmony` is **byte deterministic** — the same input always produces
identical output bytes.
