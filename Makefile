# Harmony language build

SEED      := build/c2x-seed
HB_OUT    := build/harmony-base
# Explicit order: c2x-seed resolves cross-file names from *earlier* files only,
# so foundation modules must be listed first.
HB_SRC    := \
	src/harmony-base/common.c2 \
	src/harmony-base/util.c2 \
	src/harmony-base/source.c2 \
	src/harmony-base/diag.c2 \
	src/harmony-base/lexer.c2 \
	src/harmony-base/parser.c2 \
	src/harmony-base/pipeline.c2 \
	src/harmony-base/main.c2
SEED_SRC  := $(wildcard src/c2x-seed/*.asm)

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

# c2x-seed regression corpus (guards the compiler bugs fixed during bring-up).
test-seed: seed
	bash tests/c2x-seed/run.sh

test-fuzz: harmony-base
	bash tests/harmony/fuzz.sh

clean:
	rm -rf build
