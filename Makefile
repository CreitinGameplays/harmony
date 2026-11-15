# Harmony language build

SEED      := build/c2x-seed
HB_OUT    := build/harmony-base
# Explicit order: c2x-seed resolves cross-file names from *earlier* files only,
# so foundation modules must be listed first.
# Bootstrap stage-0 compiler (c2x-seed, flat assembler) and the stage-1
# compiler (harmony-base, written in c2x-seed) live under bootstrap/
# (AGENTS.md). The pre-migration nasm sources are kept in
# bootstrap/c2x-seed-nasm/ for reference.
HB_SRC    := \
	bootstrap/harmony-base/common.c2 \
	bootstrap/harmony-base/util.c2 \
	bootstrap/harmony-base/ast.c2 \
	bootstrap/harmony-base/source.c2 \
	bootstrap/harmony-base/diag.c2 \
	bootstrap/harmony-base/reports.c2 \
	bootstrap/harmony-base/module.c2 \
	bootstrap/harmony-base/lexlit.c2 \
	bootstrap/harmony-base/lexer.c2 \
	bootstrap/harmony-base/types.c2 \
	bootstrap/harmony-base/fmt.c2 \
	bootstrap/harmony-base/check.c2 \
	bootstrap/harmony-base/cexpr.c2 \
	bootstrap/harmony-base/llvm.c2 \
	bootstrap/harmony-base/lexpr.c2 \
	bootstrap/harmony-base/lstmt.c2 \
	bootstrap/harmony-base/emit.c2 \
	bootstrap/harmony-base/parser.c2 \
	bootstrap/harmony-base/pstmts.c2 \
	bootstrap/harmony-base/pexpr.c2 \
	bootstrap/harmony-base/pastout.c2 \
	bootstrap/harmony-base/audit.c2 \
	bootstrap/harmony-base/pipeline.c2 \
	bootstrap/harmony-base/main.c2
SEED_SRC  := $(wildcard bootstrap/c2x-seed/*.asm)

.PHONY: all clean test test-fuzz test-seed seed harmony-base

all: harmony-base

seed: $(SEED)

$(SEED): $(SEED_SRC) build.sh
	bash build.sh

harmony-base: $(SEED) $(HB_SRC)
	$(SEED) -o $(HB_OUT) $(HB_SRC)

# Full test target: c2x-seed regression corpus + harmony-base driver tests.
test: test-seed harmony-base
	bash tests/harmony/run.sh
	bash tests/harmony/lexer.sh
	bash tests/harmony/parser.sh
	bash tests/harmony/checker.sh
	bash tests/harmony/error-handling.sh
	bash tests/harmony/codegen.sh
	bash tests/harmony/golden.sh
	bash tests/harmony/determinism.sh

# c2x-seed regression corpus (guards the compiler bugs fixed during bring-up).
test-seed: seed
	bash tests/c2x-seed/run.sh
	bash tests/c2x-seed/determinism.sh

test-fuzz: harmony-base
	bash tests/harmony/fuzz.sh

clean:
	rm -rf build
