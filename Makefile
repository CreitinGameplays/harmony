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
	bootstrap/harmony-base/tokdump.c2 \
	bootstrap/harmony-base/audit.c2 \
	bootstrap/harmony-base/pipeline.c2 \
	bootstrap/harmony-base/main.c2
SEED_SRC  := $(wildcard bootstrap/c2x-seed/*.asm)

.PHONY: all clean test test-final test-fuzz test-fuzz2 fuzz2-deep test-seed test-lisp seed harmony-base lisp version

all: harmony-base

seed: $(SEED)

$(SEED): $(SEED_SRC) build.sh
	bash build.sh

# The root VERSION file is auto-regenerated (AGENTS.md: SemVer 2.0.0, rolling
# support): MAJOR.MINOR.PATCH-dev|beta|stable.N+<short-commit-sha>. The base
# is preserved from the existing file; the channel, the counter, and the sha
# come from the repository state.
#
# AGENTS.md requires the file to always be up to date, so `make harmony-base`
# refreshes it after building (below) and `make version` does it on demand.
# The file is committed as part of the tree it describes; a build that moves
# the sha leaves a one-line diff, which is the point: the stamp names the
# commit it was built from.
version:
	bash tools/version.sh

harmony-base: $(SEED) $(HB_SRC)
	$(SEED) -o $(HB_OUT) $(HB_SRC)
	@bash tools/version.sh >/dev/null 2>&1 || true

# Full test target: c2x-seed regression corpus + harmony-base driver tests.
test: test-seed harmony-base
	bash tests/harmony/run.sh
	bash tests/harmony/lexer.sh
	bash tests/harmony/parser.sh
	bash tests/harmony/checker.sh
	bash tests/harmony/error-handling.sh
	bash tests/harmony/codegen.sh
	bash tests/harmony/scale.sh
	bash tests/harmony/golden.sh
	bash tests/harmony/determinism.sh
	bash tests/harmony/coverage.sh
	bash tests/harmony/version.sh
	bash tests/harmony/lisp.sh
	bash tests/harmony-final/run.sh

# c2x-seed regression corpus (guards the compiler bugs fixed during bring-up).
test-seed: seed
	bash tests/c2x-seed/run.sh
	bash tests/c2x-seed/determinism.sh

# A small LISP written in harmony-base (tests/harmony/lisp-interpreter/).
# The interpreter is split across modules and wired together with `import`
# (docs/harmony.md §6.7); `main.harmony` imports the other three.
lisp: harmony-base
	$(HB_OUT) run tests/harmony/lisp-interpreter/main.harmony

test-lisp: harmony-base
	bash tests/harmony/lisp.sh

# The self-hosted compiler's own tests: library/core and, later, the phase
# gates in roadmap/harmony. `make test` runs this too.
test-final: harmony-base
	bash tests/harmony-final/run.sh

test-fuzz: harmony-base
	bash tests/harmony/fuzz.sh

# The aggressive fuzzer (tests/fuzz2). `test-fuzz2` is the fast smoke gate:
# the deterministic adversarial shapes, no shrinking, parallel over cores.
# `fuzz2-deep` runs a real campaign (grammar + mutation, shrinking on).
test-fuzz2: harmony-base
	python3 tests/fuzz2/fuzz.py --engines specials --no-shrink

fuzz2-deep: harmony-base
	python3 tests/fuzz2/fuzz.py --engines specials,gen,mut --iterations 1000

clean:
	rm -rf build
