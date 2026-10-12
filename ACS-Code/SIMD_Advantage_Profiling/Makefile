# SIMD Advantage Profiling — build variants
#
#   make              build/<variant>/simd_bench for every variant
#   make CC=clang     another compiler (with BUILD=build-clang to keep both)
#   make test         correctness validation   (scripts/validate.sh)
#   make report       vectorization evidence   (scripts/verify_vectorization.sh)
#   make clean
#
# Build variants (record exact flags and compiler version in the report):
#   scalar    optimization on, auto-vectorization off
#   autovec   default auto-vectorized build (generic x86-64 -> SSE2, 128-bit)
#   native    targeted at the widest vector ISA of the test CPU (-march=native)
#
# Only kernels.c sees the per-variant flags. The timing harness (main.c,
# common.c) and the reference (reference.c) are compiled with fixed flags in
# every variant, so a timing difference reflects the kernel's code generation
# and never the driver's. reference.c additionally disables vectorization and
# FP contraction so it stays a trustworthy gold reference.

CC      ?= cc
BUILD   ?= build
CFLAGS  := -std=gnu11 -g -Wall -Wextra -Iinclude -I../common/include
LDLIBS  := -lm

VARIANTS := scalar autovec native

# Per-variant flags for kernels.c only.
CFLAGS_scalar  := -O3 -fno-tree-vectorize -fno-tree-slp-vectorize
CFLAGS_autovec := -O3
CFLAGS_native  := -O3 -march=native

# Fixed flags for the variant-invariant harness and the reference.
HARNESS_FLAGS := -O2
REF_FLAGS     := -O2 -fno-tree-vectorize -ffp-contract=off

HARNESS_OBJS = $(BUILD)/$*/main.o $(BUILD)/$*/common.o $(BUILD)/$*/reference.o
HEADERS := include/kernels.h ../common/include/common.h

.PHONY: all test report clean
all: $(VARIANTS:%=$(BUILD)/%/simd_bench)

.SECONDEXPANSION:
$(BUILD)/%/simd_bench: $(BUILD)/%/kernels.o $$(HARNESS_OBJS)
	$(CC) $^ -o $@ $(LDLIBS)

# kernels.c: per-variant flags, and embed the variant name/flags for --info.
$(BUILD)/%/kernels.o: src/kernels.c $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(CFLAGS_$*) -DACS_VARIANT='"$*"' -DACS_VARIANT_FLAGS='"$(CFLAGS_$*)"' -c $< -o $@

$(BUILD)/%/main.o: src/main.c $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(HARNESS_FLAGS) -c $< -o $@

$(BUILD)/%/common.o: ../common/src/common.c $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(HARNESS_FLAGS) -c $< -o $@

$(BUILD)/%/reference.o: src/reference.c $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(REF_FLAGS) -c $< -o $@

test: all
	./scripts/validate.sh

report: all
	./scripts/verify_vectorization.sh

clean:
	rm -rf $(BUILD)
