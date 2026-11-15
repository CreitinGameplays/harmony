# Harmony language
File Extension: .harmony (default), .hr (secondary)

# Rules
- Read the project layout first.
- **Read important parts of the harmony.md docs (but not everything at once)**.
- **Never** hardcode "/opencode/" in any part of the source code.
- DO proper tool calling.
- Use c2x-seed to write the harmony language:
  harmony-base: basic implementation with few features, written in c2x-seed.
  harmony: full rewrite in harmony-base itself.
  Milestone: harmony is byte deterministic.
- Fix any c2x-seed bug if you find any there (don't suppress).
- Keep source code files and subdirs well organized.
- Also fix any other bug before reporting success.
- *PRIORITIZE writing LLVM backend!! C backend comes later*
- *PREFER things to be auto resizable when possible instead of a fixed value!*
- **Both `harmony-base` and final `harmony` language should do in-memory**
  **LLVM IR compilation instead of writing .ll temp files to disk by default.**
- **What the final `harmony` language should have/support early:**
  **1. LLVM IR integrated directly into the compiler binary.**
  **2. Support to multi-core compilation by default.**
  **3. Be freestanding capable (defines custom _start entry and only core lib support).**
- Split big source files into smaller, organized files (they can be inside subdirs in the source 
  code for better organization) instead of huge single files (only exception is c2x-seed src).
- Always add new or update todo.md and docs/*.md if some info got stale, this includes updating harmony language reference/keywords.
- Use makefile to build harmony lang. build.sh builds the c2x-seed, which is written in assembly.
- Always make or update tests for any new implementation/feature,
  as well as fuzzing/aggressive tests, and add them to makefile rules.
- **ALWAYS** use your edit tool to edit source files *instead of shell scripts (including python)*.
- Never guess at bugs (harmony/c2x-seed), always reproduce:
  use any available debugger in the system (such as gdb, valgrind, strace, etc) to find the bug and fix them.
- NEVER workaround a fix on harmony-base source code to hide a genuine bug in c2x-seed.
- Always run final `make test` before completion, but only if you modify source code.
  Docs-only changes don't need to run `make test`.
- `harmony-base` is freestanding, it's the core. It should not include any stdlib 
  (see harmony.md §19.8). The full-featured compiler (with stdlib and all other features)
  will be the `harmony`, written in `harmony-base` itself. `harmony-base` should only include the bare minimum needed for a `harmony` rewrite.
- Harmony standard lib code for final language should be written in `library/`.
- It's good to also add purposely bad code (simple and complex codes).
  in error-handling directory in `tests` to verify if compiler is handling it well.
- Use `make` with `-j$(nproc)` arg to use all cores when compiling.
- Also keep compilation warning-free.
- Do not hardcode harmony.md docs sections in source code (only comments are allowed).
- All risks are accepted.
- Always add helpful comments in the code.
- Always use `-s` arg when using `git commit`.
- If a bug happens on c2x-seed during harmony implementation, pause it and only focus on fixing c2x-seed.
  When fixed just report final completion.
- You can write .harmony files in tests dir to test more complex code.
- proposed layout for the final `harmony` language (to feel more organized and clean):
```
harmony/... <- (*.hr) the real core of the language here.
├── lexer/...
├── parser/...
├── ast/...
├── codegen/... <- Backend (LLVM IR, C11...)
├── sema/... <- Type checking & semantic analysis
└── main.hr
library/
├── core/... <- (*.hr) allowed to use with freestanding (e.g primitive types, slices, iterators... just like rust).
├── std/... (HashMap/io/fs/net...) <- (*.hr) the full standard library, needs the OS/allocators...
└── (others...)
bootstrap/ <- the stage 0 compilers.
├── c2x-seed/...
├── harmony-base/...
└── runtime/... <- only for harmony-base
tests/... <- the current tests
roadmap/... <- the language roadmap
docs/... <- language documentations
(others remain the same)
```
