#!/bin/bash
# Builds c2x-seed, the stage-0 compiler written in x86-64 assembly.
#
# Default assembler: flat assembler (fasm). It is ~100x faster than nasm on
# the 89k-line programs c2x-seed emits and produces smaller, reproducible
# objects (fasm does not embed the input path, so a temp .asm name never leaks
# into the binary). The pre-migration nasm sources are kept under
# bootstrap/c2x-seed-nasm/ for reference; see bootstrap/tools/nasm_to_fasm.py
# for the mechanical conversion between the two.
#
# `-m 262144` (256 MiB) is fasm's assembly memory limit; the merged binary
# needs to hold the 16 MiB arena plus the program, and fasm aborts with
# "out of memory" on the default small limit.

set -e

MODULES="main syscalls memory types io compiler lexer parser codegen errors warnings"

mkdir -p build
for f in $MODULES; do
    # fasm prints its banner ("flat assembler ... N passes") to stdout; keep
    # the build quiet by dropping stdout (errors still go to stderr).
    fasm -m 262144 "bootstrap/c2x-seed/$f.asm" "build/$f.o" >/dev/null
done

# The module order is explicit: c2x-seed resolves cross-file names from
# *earlier* objects only, so foundation modules must link first.
ld -o build/c2x-seed \
    build/main.o build/syscalls.o build/memory.o build/types.o build/io.o \
    build/compiler.o build/lexer.o build/parser.o build/codegen.o \
    build/errors.o build/warnings.o
