# Cache & Memory Performance Profiling
#
#   make          build/<program> for every src/<program>.c
#   make clean
#
# Record the compiler version and flags used for every measurement.

CC      ?= cc
BUILD   ?= build
# -O3 -march=native: the memory system (not scalar codegen) is what we measure,
# so we want the compiler to emit the widest loads/stores and vectorized
# streaming loops the CPU supports; -fno-tree-vectorize would only add artificial
# overhead to the bandwidth kernels. -march=native targets this host's AVX2+FMA.
CFLAGS  := -std=gnu11 -O3 -march=native -g -Wall -Wextra -pthread -I../common/include
LDLIBS  := -lm -pthread

PROGRAMS := mem_latency mem_bandwidth kernel_miss
COMMON   := $(wildcard ../common/src/*.c)
HEADERS  := $(wildcard ../common/include/*.h)

.PHONY: all clean

all: $(PROGRAMS:%=$(BUILD)/%)

$(BUILD)/%: src/%.c $(COMMON) $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $< $(COMMON) -o $@ $(LDLIBS)

clean:
	rm -rf $(BUILD)
