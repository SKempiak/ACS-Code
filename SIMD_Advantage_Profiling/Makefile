# SIMD Advantage Profiling — build variants
#
#   make              build/<variant>/simd_bench for every variant
#   make CC=clang     another compiler (with BUILD=build-clang to keep both)
#   make test         correctness validation   (scripts/validate.sh)
#   make report       vectorization evidence   (scripts/verify_vectorization.sh)
#   make clean
#
# Required variants (record exact flags and compiler version in the report):
#   scalar    optimization on, vectorization off
#   autovec   default auto-vectorized build
#   native    targeted at the widest vector ISA of the test CPU

CC      ?= cc
BUILD   ?= build
CFLAGS  := -std=gnu11 -g -Wall -Wextra -Iinclude -I../common/include
LDLIBS  := -lm

VARIANTS := scalar autovec native

# TODO: compiler flags for each variant.
CFLAGS_scalar  :=
CFLAGS_autovec :=
CFLAGS_native  :=

# TODO: decide which sources get the variant flags and which must be compiled the same
# way in every variant (as written, every source gets them).
SRCS    := $(wildcard src/*.c) $(wildcard ../common/src/*.c)
HEADERS := $(wildcard include/*.h) $(wildcard ../common/include/*.h)

.PHONY: all test report clean

all: $(VARIANTS:%=$(BUILD)/%/simd_bench)

$(BUILD)/%/simd_bench: $(SRCS) $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(CFLAGS_$*) $(SRCS) -o $@ $(LDLIBS)

test: all
	./scripts/validate.sh

report: all
	./scripts/verify_vectorization.sh

clean:
	rm -rf $(BUILD)
