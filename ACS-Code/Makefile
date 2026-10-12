# Top-level build for the C projects.
#
#   make           build every C project
#   make tools     build tools/summarize
#   make clean
#
# Each project also builds on its own:  make -C <project>

CC       ?= cc
CFLAGS   := -std=gnu11 -O2 -g -Wall -Wextra -Icommon/include
COMMON   := $(wildcard common/src/*.c)
HEADERS  := $(wildcard common/include/*.h)

C_PROJECTS := SIMD_Advantage_Profiling Cache_and_Memory_Performance_Profiling

.PHONY: all tools clean $(C_PROJECTS)

all: $(C_PROJECTS)

$(C_PROJECTS):
	$(MAKE) -C $@ CC=$(CC)

tools: build/tools/summarize

build/tools/summarize: tools/summarize.c $(COMMON) $(HEADERS)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) tools/summarize.c $(COMMON) -o $@ -lm

clean:
	rm -rf build
	@for p in $(C_PROJECTS); do $(MAKE) -C $$p clean; done
