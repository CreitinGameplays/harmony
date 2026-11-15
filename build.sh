#!/bin/bash

# builds c2x-seed
mkdir -p build && for f in main syscalls memory types io compiler lexer parser codegen errors warnings; do nasm -f elf64 -Wall -Wno-reloc-abs-dword -Wno-reloc-abs-qword -Wno-reloc-rel-dword -o "build/$f.o" "bootstrap/c2x-seed/$f.asm" || exit 1; done && ld -o build/c2x-seed build/main.o build/syscalls.o build/memory.o build/types.o build/io.o build/compiler.o build/lexer.o build/parser.o build/codegen.o build/errors.o build/warnings.o
