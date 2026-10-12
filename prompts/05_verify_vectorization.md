# Prompt 05 — Verify that SIMD actually happened

I don't want to just assume the `autovec` and `native` builds vectorized — the rubric wants
evidence. Write `scripts/verify_vectorization.sh` (wired to `make report`) that, for each
variant, captures the compiler's vectorization report (GCC `-fopt-info-vec`, or the Clang
equivalent) and disassembles the kernel object with `objdump`. For each kernel function it
should count total instructions, the SIMD/packed instructions, and the widest vector
register used (xmm/ymm/zmm), and write that to `data/processed/vectorization.csv` for a
table in the report. Save the full reports and disassembly under `data/raw/` and tell me
where to find short excerpts I can quote.

I specifically want to be able to see: the vector width each variant used, whether the
multiply-add got fused into an FMA, and how the loop remainder/tail is handled. If a loop I
expected to vectorize didn't, I want the compiler's stated reason.

---
**What this demonstrates:** proving SIMD actually occurred (and at what width, with FMA,
with what tail handling) from compiler reports and disassembly, rather than inferring it
from a speedup number.
