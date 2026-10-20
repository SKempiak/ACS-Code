# SSD / storage Performance Profiling — build
#
#   make          build build/blkbench
#   make clean
#
# blkbench is a small O_DIRECT storage benchmark built on Linux libaio (the same
# async engine FIO's libaio ioengine uses). FIO is not installed on the test host,
# so this stands in for it; see src/blkbench.c and the report's methodology.
# Record the compiler version and flags used for every measurement.

CC      ?= cc
BUILD   ?= build
CFLAGS  := -std=gnu11 -O2 -g -Wall -Wextra -I../common/include
LDLIBS  := -laio

PROGRAMS := blkbench
COMMON   := $(wildcard ../common/src/*.c)
HEADERS  := $(wildcard ../common/include/*.h)

.PHONY: all clean
all: $(PROGRAMS:%=$(BUILD)/%)

$(BUILD)/%: src/%.c $(COMMON) $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $< $(COMMON) -o $@ $(LDLIBS)

clean:
	rm -rf $(BUILD)
