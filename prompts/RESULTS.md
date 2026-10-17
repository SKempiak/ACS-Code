# Simulation results — carrying out each prompt as the agent

This file records what happened when each prompt in `prompts/` was handed to an AI coding
agent and carried out against the real repository on the test machine (Intel i9-10900F,
Arch Linux, GCC 16.2.1). For every prompt: **what was asked**, **what was produced**, and
**how well it worked** — what was right and what needed correcting. The resulting code is
in `ACS-Code/SIMD_Advantage_Profiling/` and the paper in
`ACS-Latex/SIMD_Advantage_Profiling/`.

> Scope note: the repo scaffolds three class-wide projects (SIMD, Cache/Memory, SSD), which
> are alternatives — a student submits one. This simulation carries out **Project 1 (SIMD)**
> end-to-end because it is the one fully measurable on a generic dev machine (Project 3 needs
> a dedicated SSD and is data-loss-dangerous; Project 2 needs Intel MLC / `perf`). The same
> prompt-and-simulate pattern extends to the other two if wanted.

All numbers below are from real runs; nothing is fabricated. Where a tool was unavailable
(`perf`, governor control, a TeX engine) it is recorded as a limitation, not faked.

---

## Prompt 01 — Implement the kernels and references

**Asked:** implement SAXPY, dot, elementwise multiply and 3-point stencil in f32/f64 (+int32
multiply) and strided/gather SAXPY, with matching scalar references, keeping the source
auto-vectorizable.

**Produced:** `src/kernels.c`, `src/reference.c`, `include/kernels.h` — four kernels × two
float types, int32 multiply, and `saxpy_f32_stride` / `saxpy_f32_gather`.

**How well it worked:** Correct on the first implementation. The only design decisions that
needed thought were (a) the stencil endpoints — the agent copied `x[0]`/`x[n-1]` into
`y`, which the reference matches, so validation is well-defined at the boundaries; and (b)
keeping the reductions as a simple running sum rather than anything clever, so the *scalar*
reference stays a faithful oracle. Later validated at 570/570 cases (Prompt 03/04). No
correction required.

---

## Prompt 02 — Fill in the build variants

**Asked:** set `scalar` / `autovec` / `native` flags, justify them, and compile only the
kernel TU with the variant flags while keeping the harness and reference invariant.

**Produced:** `Makefile` with
`scalar = -O3 -fno-tree-vectorize -fno-tree-slp-vectorize`, `autovec = -O3`,
`native = -O3 -march=native`; the reference compiled with `-O2 -fno-tree-vectorize
-ffp-contract=off`; the harness with a fixed `-O2`. The binary prints its variant/flags via
`--info`.

**How well it worked:** The flag choices were right, but the skeleton's single build rule
compiled *every* source with the variant flags — exactly the "driver compiled with kernel
flags" trap. Had to restructure the Makefile into per-object rules (`kernels.o` with the
variant flags, `main.o`/`common.o`/`reference.o` fixed) using `.SECONDEXPANSION`.
**Real finding that became a report point:** the agent first assumed `autovec` would give
the widest vectors; `make report` showed it only reached **SSE 128-bit (xmm)** because the
default target is generic `x86-64`. That is precisely why a separate `native`
(`-march=native` → AVX2 256-bit **ymm**) variant is needed — now documented in
§Methodology and §Vectorization.

---

## Prompt 03 — Write the benchmark driver

**Asked:** a one-config-per-invocation driver with CLI knobs, deterministic init,
validate-before-timing, calibrated repeated timing, throughput/ns-per-element output, and
shared helpers in `common/`.

**Produced:** `src/main.c` (config parsing, data alloc/init, `validate()`, `calibrate_iters()`,
timed loop, CSV rows) and `common/common.c` (`acs_now_sec`, `acs_alloc` with offset,
`acs_pin_cpu`, `acs_consume_*`, checksums).

**How well it worked:** Solid. The dead-code-elimination concern was handled two ways:
kernels live in their own translation unit (no cross-TU inlining without LTO, so the call
can't be elided) **and** every result is pushed through a `volatile` sink. We checked this
is not theatre — an early single-TU prototype of the dot loop, compiled at `-O3` with the
accumulator unused, was indeed optimized away to a near-zero time; the separate-TU + sink
design is what prevents it. SAXPY's in-place accumulation over a timed batch was a subtle
point: it grows `y` only *linearly* in the iteration count (not exponentially), so it never
overflows float32, and `reset_y()` restores a known state before timing. Added
`--selftest` (known-answer checks) on top of the reference comparison.

---

## Prompt 04 — Run scripts and data processing

**Asked:** `run.sh` with per-experiment entry points writing raw+processed data, and
`tools/summarize.c` producing medians/IQR with column names matching the pgfplots figures.

**Produced:** `scripts/run.sh` (baseline/locality/alignment/stride/dtype/negative/all),
`tools/summarize.c` (generic group-by + median/q25/q75 + `speedup_vs_scalar`).

**How well it worked:** The pipeline worked, but the **column/filter contract** needed a
correction — the exact risk the prompt flagged. Two mismatches surfaced when cross-checking
against the `.tex` files:
1. The baseline figure filters `only if={kernel}{saxpy}` and reads `elems_per_s_median` /
   `iqr of=elems_per_s` (expands to `elems_per_s_q25/q75`) and `speedup_vs_scalar`.
   `summarize` had to emit exactly those names; its `--stat elems_per_s` auto-generates
   `_median/_q25/_q75`, and `--speedup` adds `speedup_vs_scalar`. Verified they match.
2. The stride figure's example filter hard-coded `only if={n}{16777216}`, but a stride-16
   sweep at N=16.7M allocates ~16 GB; we measured the DRAM point at **N=4194304** instead
   and **updated the `.tex` filter to `4194304`** to match the data. (Classic "silent empty
   plot" trap — caught by reading the figure, not the data.)

---

## Prompt 05 — Verify that SIMD actually happened

**Asked:** a `make report` script capturing compiler vec reports + `objdump`, counting SIMD
instructions and widest register per function into `vectorization.csv`.

**Produced:** `scripts/verify_vectorization.sh` recompiling `kernels.c` per variant with
`-fopt-info-vec`, disassembling, and an `awk` classifier for packed instructions.

**How well it worked:** The evidence is exactly what the report needed — scalar: 0 vectorized
loops; autovec: 128-bit xmm; native: 256-bit ymm with `vfmadd213ps`, unroll 8, and a 128-bit
vectorized epilogue for the tail. But the first version had **two real bugs, both caught by
running it**:
- The `awk` wrote to a CSV path passed as a trailing `VAR=value` argument; those are only
  assigned when awk *reaches* that argument, so in `BEGIN` the variable was empty and awk
  died with `expression for '>>' redirection has null string value`. Fixed by passing it
  with `-v csv=...`.
- A `grep -c ... || echo 0` double-printed the count (grep already prints `0`). Fixed.

One honest nuance we chose to **document rather than hide**: the scalar build shows 1–4
"SIMD" matches on some kernels. Inspecting the disassembly showed these are `pxor`/`movaps`
register-clears and scalar-in-xmm moves, not vectorized loop bodies — so the report says so
explicitly and leans on the compiler's "0 loops vectorized" for scalar.

---

## Prompt 06 — Design the negative / failure case

**Asked:** a rigorous memory-bound negative case (vectorized but no speedup), tied to a
bandwidth number, plus any "looks-vectorized-but-slow" kernel.

**Produced:** the `negative` experiment (SAXPY swept 1 Ki → 32 Mi elements) and the roofline
inputs.

**How well it worked:** Clean result. SAXPY speedup falls 5.83× (L1) → 1.34× (256 MB DRAM)
even though the disassembly proves it's 256-bit FMA vectorized. Derived single-core
streaming bandwidth ≈ 45 GB/s from the DRAM throughput and showed SAXPY sits essentially
*on* the roofline's bandwidth slope, so the explanation is quantitative, not hand-wavy.
**Bonus anomaly the agent surfaced unprompted:** the dot product reports "loop vectorized"
and the disassembly shows a 256-bit `vmulps`, but the reduction is a *serial* scalar
`vaddss` chain (no `-ffast-math` → no FP reassociation), so its real speedup is ~1×. That
became a second negative/anomaly example — a stronger "it vectorized ≠ it's fast" point than
the one asked for.

---

## Prompt 07 — Review AI use and draft an honest note

**Asked:** an honest AI-use note reflecting generation vs. verification, including a caught
mistake.

**Produced:** updated `ACS-Code/AI_USE_LOG.md` and the report's §AI-Use.

**How well it worked:** Straightforward. The note names the tool/model, what was generated
(kernels, harness, scripts, report prose), and concrete corrections — the Makefile
single-rule trap (Prompt 02), the column/filter drift (Prompt 04), and the `awk` null-redirect
bug (Prompt 05) as the explicit "AI suggestion was wrong and here's how it was caught" item.
Kept it unflattering per the request.

---

## Prompt 08 — Critique the benchmark for AI-generated-code pitfalls

**Asked:** adversarially audit for DCE, cache-vs-DRAM, pinning, frequency scaling, timer
resolution, and unverified vectorization.

**Produced:** a point-by-point audit (summarized here and reflected in §Methodology and
§Anomalies).

**How well it worked:** Most pitfalls were already handled, and the audit forced them to be
*demonstrated* rather than asserted:
- **DCE:** handled (separate TU + `volatile` sink); confirmed the timed loop is real because
  SAXPY's per-rep checksum changes every repetition (it accumulates) and dot's result is
  consumed.
- **Cache vs DRAM:** the "DRAM" sizes (≥ 2²⁴ elems = 64 MB per array) are safely past the
  20 MB L3; the locality curve's knees line up with L1/L2/L3 sizes, confirming the regime.
- **Pinning / SMT / frequency:** runs are pinned to one physical core; SMT sibling left idle;
  **documented limitation** — governor is `powersave` with turbo on and could not be changed
  in this environment, and `perf` is not installed (`perf_event_paranoid=2`), so no hardware
  counters. Both are stated in §Anomalies rather than papered over.
- **Timer:** each timed batch is ≥ 25 ms vs a 1 ns-resolution clock — ~2.5×10⁷ ticks, so
  resolution and call overhead are negligible.
- **Scalar really scalar / width verified:** confirmed via `make report`, not assumed.

No numbers changed as a result; the audit's value was turning "we did it right" into "here
is the evidence we did it right," which is where the rubric's points are.

---

## Build / verification status on this machine

- `make -C ACS-Code/SIMD_Advantage_Profiling` builds all three variants cleanly (GCC 16.2.1).
- `make test` → **570/570** correctness cases pass across scalar/autovec/native.
- `make report` → scalar 0 vectorized loops, autovec xmm(128), native ymm(256)+FMA.
- `scripts/run.sh all` → `data/processed/{baseline,locality,alignment,stride,dtype,negative}.csv`
  and `vectorization.csv`; `sync_data.sh` copies them into `ACS-Latex/.../data/`.
- **LaTeX build (now verified).** TeX Live is installed on the test host, so `make simd` and
  `make final` were run here: both exit 0, all three PDFs regenerate, and the SIMD log has
  zero `! ` errors, zero `Package acs Warning`, and a
  non-empty bibliography (`williams2009roofline` renders as `[1]`; no `[?]` markers in the
  output). The only reference-related log line is the benign `biblatex` "There were undefined
  references" / "Please (re)run BibTeX" notice inherent to the `bibtex` backend (biber absent);
  it does not affect the rendered PDF and is documented in §Limitations. The
  `Package acs Warning` lines reported by `make final` come only from the untouched
  memory/SSD scaffolds (TODO / `\tbd` / missing-data), as designed.

---

## 2026-10-17 — build fix (returned issue): SIMD report would not compile

The SIMD report build (`make simd`) failed on the test host. Two problems, both fixed:

1. **siunitx range inside `\qty` (the hard error).** `sections/07_alignment_tail.tex:49` wrote
   `\qty{0.080\text{--}0.090}{\nano\second}` — a dash range is not a parseable siunitx *number*,
   so `pdflatex` threw `Package siunitx Error: Invalid number`, and under nonstopmode the runaway
   argument corrupted the parse of the next section (`Missing $`, `Missing \endgroup`). latexmk
   then aborted before biber/reruns, which is why the tester *also* saw ~60 "undefined reference"
   and an "Empty bibliography" — all downstream symptoms of the early abort, not independent bugs.
   **Fix:** `\qtyrange{0.080}{0.090}{\nano\second}` and, for consistency, the adjacent percentage
   range → `\SIrange{40}{60}{\percent}`. Renders as "≈ 0.080 ns to 0.090 ns, i.e. a 40 % to 60 %
   slowdown." This is the correction the plan identified as the single root cause. *(Example of
   AI-generated LaTeX that looked plausible but was syntactically invalid — caught only at build.)*

2. **biber not installed on the test host (environment deviation).** With the siunitx error fixed,
   `pdflatex` reached the biography step, but `biblatex` was configured `backend=biber` and **biber
   is not installed** here (only `bibtex`; no sudo to install biber). latexmk therefore still failed
   (`biber: command not found`). The plan assumed biber would run; reality forced a deviation
   (recorded as an issue note). **Fix:** switched `common/preamble.tex` to `backend=bibtex`, changed
   `\addbibresource{../common/references.bib}` to the bare name `references.bib`, and added
   `BIBINPUTS` (absolute path to `common/`) to each project's `latexmkrc` so `bibtex` — which runs
   from `build/` and resolves slash-containing names relative to its CWD — can find the shared
   `references.bib`. After this, `make simd` and `make final` exit 0 and the bibliography resolves.
   One benign, unavoidable artifact of the `bibtex` backend remains: `biblatex` prints
   "Please (re)run BibTeX" on the final pass. It does not affect output (verified: no `[?]`, cite
   renders `[1]`) and is documented in the report's §Anomalies/Limitations. Restoring
   `backend=biber` on a host with biber installed removes the notice.
