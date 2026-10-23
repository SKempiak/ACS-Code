# Cache & Memory Performance Profiling
#
#   make          build/<program> for every src/<program>.c
#   make test     scripts/validate.sh (physical-ordering sanity checks, ~15 s)
#   make clean
#
# Record the compiler version and flags used for every measurement.

CC      ?= cc
BUILD   ?= build
# -O3 -march=native: the memory system (not scalar codegen) is what we measure,
# so we want the compiler to emit the widest loads/stores and vectorized
# streaming loops the CPU supports; -fno-tree-vectorize would only add artificial
# overhead to the bandwidth kernels. -march=native targets this host's AVX2+FMA.
CFLAGS  := -std=gnu11 -O3 -march=native -g -Wall -Wextra -pthread -I../../common/code/include -Isrc
LDLIBS  := -lm -pthread

PROGRAMS := mem_latency mem_bandwidth mem_loaded kernel_miss clock_check
COMMON   := $(wildcard ../../common/code/src/*.c)
HEADERS  := $(wildcard ../../common/code/include/*.h) $(wildcard src/*.h)

.PHONY: all clean test print-cflags

all: $(PROGRAMS:%=$(BUILD)/%)

$(BUILD)/%: src/%.c $(COMMON) $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $< $(COMMON) -o $@ $(LDLIBS)

print-cflags:
	@echo '$(CFLAGS)'

test: all
	scripts/validate.sh

clean:
	rm -rf $(BUILD)
