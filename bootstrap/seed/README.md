# Stage-0 seed

`harmony-seed` is the frozen stage-0 compiler for this tree: a byte-identical
stage-1 build of the self-hosted `harmony` compiler itself. It replaces the
legacy `c2x-seed` → `harmony-base` bootstrap, which is preserved on the
`legacy/bootstrap` branch and tagged `legacy/bootstrap-final`.

The binary is **not stored in this repository**. It is published as a release
asset on the `stage0-v1` tag and downloaded on demand by `make harmony` into
gitignored `build/seed/`. This directory keeps only its provenance:

- `SHA256SUMS` — the exact bytes every build verifies before executing the seed.
- [release](https://github.com/CreitinGameplays/harmony/releases/tag/stage0-v1) — `harmony-seed` and the same checksum file.

`make verify-seed` checks the fetched (or locally supplied) binary. Pin a
local copy for offline builds with `make SEED_BIN=/path/to/harmony-seed ...`;
its hash must still match `SHA256SUMS`. `SEED_URL` can point at a mirror.

The seed was qualified with `make qualify-seed`: stage 1, stage 2 and stage 3
are byte-identical. `make harmony` runs
`harmony-seed build harmony/main.hr -o build/harmony`, so the canonical
compiler is always built through the same native LLVM-C path as the seed that
produced it.

The seed is linked against LLVM/LLD 21 (`libLLVM.so.21.1`) with an RPATH
resolved by the build environment's `llvm-config`; rebuilding with a different
LLVM major produces a compiler with that major's codegen. The CI image installs
`llvm-dev`/`liblld-dev` to match.
