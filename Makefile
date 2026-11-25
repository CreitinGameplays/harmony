# Harmony language build — seed-only (post bootstrap-retirement).
#
# The canonical compiler is `harmony`, the self-hosted implementation in
# harmony/ + library/. It is built by the frozen stage-0 seed: a byte-identical
# stage-1 build of itself, published as a release asset and downloaded on
# demand. The repo keeps only its checksum and provenance under bootstrap/seed/.
# The legacy c2x-seed and harmony-base toolchains are preserved on the
# `legacy/bootstrap` branch, tagged `legacy/bootstrap-final`, and are no part
# of this tree.

# SEED_BIN can point at a local copy for offline builds; otherwise the seed is
# fetched from SEED_URL and verified against the committed checksum.
SEED_BIN    ?= $(CURDIR)/build/seed/harmony-seed
SEED_URL    ?= https://github.com/CreitinGameplays/harmony/releases/download/stage0-v1/harmony-seed
SEED_SUM    := bootstrap/seed/SHA256SUMS
SEED_SHA256 := $(shell cut -d' ' -f1 $(SEED_SUM))
HARMONY_SRC := $(shell find harmony library -name '*.hr' -o -name '*.harmony' 2>/dev/null)
HARMONY_OUT := build/harmony

# The compiler under test is the canonical binary; there is no separate
# legacy lane any more. The differential suites that needed a second compiler
# were retired with it, and now check determinism against this same binary.
HARMONY ?= $(CURDIR)/build/harmony
HC      ?= $(CURDIR)/build/harmony
HB      ?= $(CURDIR)/build/harmony
export HARMONY HC HB

# The compiler links the LLVM C API directly for build/run. Its runtime
# sources are built here; the compiler itself never shells out to clang on the
# default path.
LLVM_LIBDIR   := $(shell llvm-config --libdir)
LLVM_MAJOR    := $(shell llvm-config --version | cut -d. -f1)
LLVM_CFLAGS   := $(shell llvm-config --cflags)
LLVM_SYSLIBS  := $(shell llvm-config --link-static --system-libs)
LLVM_LINK     := -L$(LLVM_LIBDIR) -Wl,-rpath,$(LLVM_LIBDIR) -llldELF -llldCommon -lLLVM-$(LLVM_MAJOR) $(LLVM_SYSLIBS)
CXXFLAGS      := -std=c++17 -O2 $(LLVM_CFLAGS)
LLVMC_OBJ     := build/llvmc.o
HOSTRT_OBJ    := build/hostrt.o
HOSTMAIN_OBJ  := build/hostmain.o

.PHONY: all clean test test-final test-fuzz test-fuzz2 fuzz2-deep \
        qualify-seed verify-seed version harmony

all: harmony

build:
	mkdir -p build

build/seed:
	mkdir -p build/seed

# Fetch the stage-0 seed on demand. Verification happens before the binary is
# ever executed: a corrupted or tampered asset fails the build here.
$(SEED_BIN): $(SEED_SUM) | build/seed
	curl -fsSL --retry 3 "$(SEED_URL)" -o $@
	printf '%s  %s\n' "$(SEED_SHA256)" "$@" | sha256sum -c -
	chmod 755 $@

# The root VERSION file is auto-regenerated (AGENTS.md: SemVer 2.0.0, rolling
# support): MAJOR.MINOR.PATCH-dev|beta|stable.N+<short-commit-sha>. It is
# committed as part of the tree it describes; `make version` refreshes it on
# demand.
version:
	bash tools/version.sh

verify-seed: $(SEED_BIN)
	printf '%s  %s\n' "$(SEED_SHA256)" "$(SEED_BIN)" | sha256sum -c -

# One canonical stage: the seed rebuilds the compiler through the native
# LLVM-C backend, which is the same path every later stage uses. That keeps
# stage 1, stage 2 and stage 3 byte-identical.
harmony: $(SEED_BIN) $(HARMONY_SRC) $(LLVMC_OBJ) $(HOSTRT_OBJ) $(HOSTMAIN_OBJ) | build
	$(SEED_BIN) build harmony/main.hr -o $(HARMONY_OUT)

# A seed may stand for another stage only if it rebuilds itself byte-for-byte
# through two further self-host passes.
qualify-seed: harmony
	./build/harmony build harmony/main.hr -o build/seed-candidate-2
	build/seed-candidate-2 build harmony/main.hr -o build/seed-candidate-3
	cmp build/harmony build/seed-candidate-2
	cmp build/seed-candidate-2 build/seed-candidate-3
	@echo "SEED QUALIFIED stage1==stage2==stage3: $$(sha256sum build/harmony | cut -d' ' -f1)"

test: harmony
	bash tests/harmony/run.sh
	bash tests/harmony/lexer.sh
	bash tests/harmony/parser.sh
	bash tests/harmony/checker.sh
	bash tests/harmony/error-handling.sh
	bash tests/harmony/codegen.sh
	bash tests/harmony/scale.sh
	bash tests/harmony/determinism.sh
	# determinism.sh runs `make clean`; rebuild before the remaining suites.
	$(MAKE) harmony
	bash tests/harmony/string-pool.sh
	bash tests/harmony/version.sh
	bash tests/harmony/lisp.sh
	bash tests/harmony/fuzz.sh
	bash tests/harmony-final/run.sh
	bash tests/harmony-final/driver.sh
	bash tests/harmony-final/parallel.sh
	bash tests/harmony-final/v1.sh
	bash tests/harmony-final/m2.sh
	bash tests/harmony-final/m3.sh
	bash tests/harmony-final/m4.sh
	bash tests/harmony-final/m6.sh
	bash tests/harmony-final/diag.sh
	bash tests/harmony-final/fmt.sh
	bash tests/harmony-final/prelude.sh
	bash tests/harmony-final/strategy.sh

test-final: harmony
	bash tests/harmony-final/run.sh
	bash tests/harmony-final/driver.sh
	bash tests/harmony-final/parallel.sh
	bash tests/harmony-final/v1.sh
	bash tests/harmony-final/m2.sh
	bash tests/harmony-final/m3.sh
	bash tests/harmony-final/m4.sh
	bash tests/harmony-final/m6.sh
	bash tests/harmony-final/diag.sh
	bash tests/harmony-final/fmt.sh
	bash tests/harmony-final/prelude.sh
	bash tests/harmony-final/strategy.sh

test-fuzz: harmony
	bash tests/harmony/fuzz.sh

test-fuzz2: harmony
	python3 tests/fuzz2/fuzz.py --engines specials --no-shrink

fuzz2-deep: harmony
	python3 tests/fuzz2/fuzz.py --engines specials,gen,mut --iterations 1000

$(LLVMC_OBJ): library/runtime/llvmc.cpp library/runtime/llvmc_core.cpp | build
	clang++ $(CXXFLAGS) -fPIC -c $< -o $@

# Rename `_start` so the C runtime startup can initialise libc before libLLVM
# is used. The wrapper in hostmain.c supplies the real `main`.
$(HOSTRT_OBJ): library/runtime/rt.c | build
	clang -O2 -D_start=hc_unused_start -c $< -o $@

$(HOSTMAIN_OBJ): library/runtime/hostmain.c | build
	clang -O2 -c $< -o $@

clean:
	rm -rf build
