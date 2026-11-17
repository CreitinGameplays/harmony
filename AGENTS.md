# Harmony language
File Extension: .harmony (default), .hr (secondary)

# Rules
- Read the project layout first.
- **Read important parts of the harmony.md docs (but not everything at once)**.
- **Never** hardcode "/opencode/" in any part of the source code.
- **Final `harmony` and its future compiler updates will use Semantic Versioning 2.0.0 (and all of its rules) and**
  **Rolling Support only (no bugfix backporting to previous branches)!**
  MAJOR = breaking API changes (like major refactor/rewrites...).
  MINOR = improvements, small additions, backwards compatible (e.g, `1.8` still must compile `1.0`/`1.1` era-code).
  PATCH = bug fixes.
  Root dir `VERSION` file must be auto re-generated: `MAJOR.MINOR.PATCH-dev/beta/stable.number+<short-commit-sha>`.
  Example: `1.0.0-dev.1+130fa507`. Branches names should be as follows (just an example): `1.0`, `1.1`, `2.0`, and so on.
  `1.0` will only come once the final `harmony` language is fully implemented.
- Make sure `VERSION` is always up-to-date.
- Use c2x-seed to write the harmony language:
  harmony-base: basic implementation with few features, written in c2x-seed.
  harmony: full rewrite in harmony-base itself.
  Milestone: harmony is byte deterministic.
- Fix any c2x-seed bug if you find any there (don't suppress).
- Keep source code files and subdirs well organized.
- Temp files must go outside repo dir (use `/tmp` instead).
- Also fix any other bug before reporting success.
- *PRIORITIZE writing LLVM backend!! C backend comes later*
- *PREFER things to be auto resizable when possible instead of a fixed value!*
- **Both `harmony-base` and final `harmony` language should do in-memory**
  **LLVM IR compilation instead of writing .ll temp files to disk by default.**
- **What the final `harmony` language should have/support early:**
  **1. LLVM IR integrated directly into the compiler binary.**
  **2. Support to multi-core compilation by default.**
  **3. Be freestanding capable (defines custom _start entry with extern and only core lib support).**
- **`harmony-base` must be as optimized as possible for single-core comp.,**
  **and final language should prioritize multi-core optimizations.**
- If the information in the documentation contradicts the actual implementation, reconsider and **choose the safer long-term option** (updating either the code or the documentation).
- Split big source files into smaller, organized files (they can be inside subdirs in the source 
  code for better organization) instead of huge single files (only exception is c2x-seed src).
- Always add new or update todo.md and docs/*.md if some info got stale, this includes updating harmony language reference/keywords.
- Use makefile to build harmony lang. build.sh builds the c2x-seed, which is written in assembly.
- **Always make or update tests for any new implementation/feature, code fixes,**
  **as well as fuzzing/aggressive and more importantly, error-handling tests, put them all to make test!**
- **Critical: it's very important to have as many edge cases/error tests as possible here! Never forget it.**
- **ALWAYS** use your edit tool to edit source files *instead of shell scripts (including python)*.
- Always measure the speed of your manual shell fuzz tests.
- Never guess at bugs (harmony/c2x-seed), always reproduce:
  use any available debugger in the system (such as gdb, valgrind, strace, etc) to find the bug and fix them.
- NEVER workaround a fix on harmony-base source code to hide a genuine bug in c2x-seed.
- Always run final `make test` before commiting/completion, but only if you modify source code.
  Docs-only changes don't need to run `make test`.
- `harmony-base` is freestanding, it's the core. It should not include any stdlib 
  (see harmony.md §19.8). The full-featured compiler (with stdlib and all other features)
  will be the `harmony`, written in `harmony-base` itself. `harmony-base` should only include the bare minimum needed for a `harmony` rewrite.
- Harmony standard lib code for final language should be written in `library/`.
  in error-handling directory in `tests` to verify if compiler is handling it well.
- Use `make` with `-j$(nproc)` arg to use all cores when compiling.
- Also keep compilation warning-free.
- **Do NOT** hardcode harmony.md docs sections (§) in source code (only in code comments they are allowed).
- All risks are accepted.
- Always add helpful comments in the code.
- Always use `-s` arg when using `git commit`.
- If a bug happens on c2x-seed during harmony implementation, pause it and only focus on fixing c2x-seed.
  When fixed just report final completion.
- You can write .harmony files in tests dir to test more complex code.
- You'll use `import`s for final harmony language.
- proposed layout for the final `harmony` language (to feel more organized and clean):
```
harmony/... <- (*.hr) the real core of the language. No std library features here.
├── lexer/...
├── parser/...
├── ast/...
├── cache/... <- Cache related code.
├── codegen/... <- Backend (LLVM IR, C11...)
├── ir/... <- CFG IR
├── sema/... <- Semantic analysis
├── borrowck/... <- Borrow checker
├── driver/... <- CLI
└── main.hr
library/
├── core/... <- (*.hr) allowed to use with freestanding (e.g primitive types, slices, iterators... no allocator).
├── alloc/... <- (*.hr) allocator hook.
├── std/... (HashMap/io/fs/net...) <- (*.hr) the full standard library, needs the OS.
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
