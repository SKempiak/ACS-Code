# SSD / storage Performance Profiling — build
#
#   make          build build/blkbench
#   make test     safety-gate refusals + physical-sanity checks (scripts/validate.sh);
#                 writes <= ~200 MiB to a scratch file and deletes it
#   make clean
#
# blkbench is a small O_DIRECT storage benchmark built on Linux libaio (the same
# async engine FIO's libaio ioengine uses). It is the primary engine; when fio is
# installed, `scripts/run.sh fio_check` cross-checks it against FIO.
# Record the compiler version and flags used for every measurement.

CC      ?= cc
BUILD   ?= build
CFLAGS  := -std=gnu11 -O2 -g -Wall -Wextra -I../common/include
LDLIBS  := -laio

PROGRAMS := blkbench
COMMON   := $(wildcard ../common/src/*.c)
HEADERS  := $(wildcard ../common/include/*.h)

.PHONY: all clean test
all: $(PROGRAMS:%=$(BUILD)/%)

$(BUILD)/%: src/%.c $(COMMON) $(HEADERS) Makefile
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $< $(COMMON) -o $@ $(LDLIBS)

test: all
	./scripts/validate.sh

clean:
	rm -rf $(BUILD)
