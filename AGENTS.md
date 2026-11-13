# Harmony language
File Extension: .harmony
Check

# Rules
- Read the project layout first.
- Read important parts of the docs (but not everything at once).
- Use c2x-seed to write the harmony language:
  harmony-base: basic implementation with few features, written in c2x-seed.
  harmony: full rewrite in harmony-base itself.
  Milestone: harmony is byte deterministic.

- Fix any c2x-seed bug if you find any there (don't suppress).
- Keep source code files and subdirs well organized.
- Also fix any other bug before reporting success.
- *PRIORITIZE writing LLVM backend!!*
- Split big source files into smaller, organized files instead of huge single files (only exception is c2x-seed src).
- Always add new or update todo.md and docs/* if some info got stale, this includes updating harmony language reference/keywords.
- Use makefile to build harmony lang. build.sh builds the c2x-seed, which is written in assembly.
- Always make or update tests for any new implementation/feature,
  as well as fuzzing/aggressive tests, and add them to makefile rules.
- Use your edit tool to edit source files *instead of shell scripts (including python)*.
