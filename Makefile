# Top-level build: C code and LaTeX reports for every project.
#
#   make                build every C project (<project>/code)
#   make tools          build common/code/build/tools/summarize
#   make reports        all reports, draft mode (rubric boxes and data placeholders visible)
#   make simd | memory | ssd
#   make final          all reports in final mode (rubric boxes hidden; warns on TODO,
#                       unmeasured \tbd values and missing data)
#   make watch-simd     rebuild a report on every save (also watch-memory, watch-ssd)
#   make clean
#
# Each project's code also builds on its own:  make -C <project>/code
# Each PDF is copied to <project>/latex/<project>.pdf.

ifneq ($(wildcard /Library/TeX/texbin),)
export PATH := /Library/TeX/texbin:$(PATH)
endif

CC       ?= cc
LATEXMK  ?= latexmk
COMMON_CODE := common/code
CFLAGS   := -std=gnu11 -O2 -g -Wall -Wextra -I$(COMMON_CODE)/include
COMMON   := $(wildcard $(COMMON_CODE)/src/*.c)
HEADERS  := $(wildcard $(COMMON_CODE)/include/*.h)

simd     := SIMD_Advantage_Profiling
memory   := Cache_and_Memory_Performance_Profiling
ssd      := SSD_Performance_Profiling
PROJECTS := $(simd) $(memory) $(ssd)

.PHONY: all code tools reports final clean simd memory ssd $(PROJECTS)

all: code

code:
	@for p in $(PROJECTS); do $(MAKE) -C $$p/code CC=$(CC) || exit 1; done

tools: $(COMMON_CODE)/build/tools/summarize

$(COMMON_CODE)/build/tools/summarize: $(COMMON_CODE)/tools/summarize.c $(COMMON) $(HEADERS)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(COMMON_CODE)/tools/summarize.c $(COMMON) -o $@ -lm

reports: $(PROJECTS)
simd: $(simd)
memory: $(memory)
ssd: $(ssd)

$(PROJECTS):
	cd $@/latex && $(LATEXMK) main.tex
	cp $@/latex/build/main.pdf $@/latex/$@.pdf

final:
	@for p in $(PROJECTS); do \
	  (cd $$p/latex && $(LATEXMK) -g -usepretex='\def\acsfinal{}' main.tex) || exit 1; \
	  cp $$p/latex/build/main.pdf $$p/latex/$$p.pdf; \
	done
	@grep -H "Package acs Warning" $(addsuffix /latex/build/main.log,$(PROJECTS)) \
	  || echo "No TODOs, unmeasured values or missing data files."

watch-%:
	cd $($*)/latex && $(LATEXMK) -pvc main.tex

clean:
	rm -rf $(COMMON_CODE)/build
	@for p in $(PROJECTS); do \
	  $(MAKE) -C $$p/code clean; \
	  (cd $$p/latex && $(LATEXMK) -C main.tex >/dev/null); rm -rf $$p/latex/build; \
	done
