# Stage-0 seed

`harmony-seed` is the frozen stage-0 compiler for this tree: a byte-identical
stage-1 build of the self-hosted `harmony` compiler itself. It replaces the
legacy `c2x-seed` → `harmony-base` bootstrap, which is preserved on the
`legacy/bootstrap` branch and tagged `legacy/bootstrap-final`.

The seed was qualified with `make qualify-seed`: stage 1, stage 2 and stage 3
are byte-identical, and `sha256sum -c SHA256SUMS` verifies this exact binary.
`make harmony` runs `harmony-seed build harmony/main.hr -o build/harmony`, so
the canonical compiler is always built through the same native LLVM-C path as
the seed that produced it.

The seed is linked against LLVM/LLD 21 (`libLLVM.so.21.1`) with a relative
RPATH resolved by the build environment's `llvm-config`; rebuilding with a
different LLVM major produces a compiler with that major's codegen. The CI
image installs `llvm-dev`/`liblld-dev` to match.
