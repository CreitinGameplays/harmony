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

## Usage (planned)

```bash
harmony-base check main.harmony          # parse + check only
harmony-base build main.harmony -o hello # compile to a binary
harmony-base run main.harmony            # compile and run
harmony-base --explain borrow.conflict   # long-form help for a report
```

Milestone: `harmony` is **byte deterministic** — the same input always produces
identical output bytes.
