# Build the ACS class-wide project reports (TeX Live: latexmk, pdflatex, biber).
#
#   make                all reports, draft mode (rubric boxes and data placeholders visible)
#   make simd | memory | ssd
#   make final          all reports in final mode (rubric boxes hidden; warns on TODO,
#                       unmeasured \tbd values and missing data)
#   make watch-simd     rebuild on every save (also watch-memory, watch-ssd)
#   make clean
#
# Each PDF is copied to <project>/<project>.pdf.

ifneq ($(wildcard /Library/TeX/texbin),)
export PATH := /Library/TeX/texbin:$(PATH)
endif

LATEXMK  ?= latexmk
simd     := SIMD_Advantage_Profiling
memory   := Cache_and_Memory_Performance_Profiling
ssd      := SSD_Performance_Profiling
PROJECTS := $(simd) $(memory) $(ssd)

.PHONY: all final clean simd memory ssd $(PROJECTS)

all: $(PROJECTS)
simd: $(simd)
memory: $(memory)
ssd: $(ssd)

$(PROJECTS):
	cd $@ && $(LATEXMK) main.tex
	cp $@/build/main.pdf $@/$@.pdf

final:
	@for p in $(PROJECTS); do \
	  (cd $$p && $(LATEXMK) -g -usepretex='\def\acsfinal{}' main.tex) || exit 1; \
	  cp $$p/build/main.pdf $$p/$$p.pdf; \
	done
	@grep -H "Package acs Warning" $(addsuffix /build/main.log,$(PROJECTS)) \
	  || echo "No TODOs, unmeasured values or missing data files."

watch-%:
	cd $($*) && $(LATEXMK) -pvc main.tex

clean:
	@for p in $(PROJECTS); do (cd $$p && $(LATEXMK) -C main.tex >/dev/null); rm -rf $$p/build; done
