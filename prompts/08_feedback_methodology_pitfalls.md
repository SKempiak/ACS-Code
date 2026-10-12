# Prompt 08 — Critique my benchmark for AI-generated-code pitfalls

Before I submit, act as a skeptical reviewer and try to break my methodology — specifically
the kinds of mistakes that AI-generated benchmark code falls into and that would make my
numbers misleading. Go through the driver, the run scripts and the kernels and check for at
least these:

- Dead-code elimination: could the compiler have deleted a kernel (especially the dot
  product, whose result is a scalar) so I'm "measuring" nothing? How do you know it didn't?
- Am I accidentally measuring cache reuse instead of DRAM when I claim a result is
  memory-bound? Are my "DRAM" sizes actually larger than the 20 MB L3?
- Thread pinning and frequency: am I pinned to one core? Is SMT or turbo/governor going to
  distort the medians, and did I document it?
- Timer: is the timed interval long enough relative to the clock resolution and call
  overhead?
- Does the `scalar` build actually stay scalar, and did I verify vector width rather than
  assume it?

For each issue, tell me whether my setup already handles it, and if not, what to change.
I'd rather find these now than have the grader find them.

---
**What this demonstrates:** using AI adversarially to harden methodology — auditing for the
exact benchmarking pitfalls (DCE, cache-vs-DRAM, pinning, frequency scaling, timer
resolution, unverified vectorization) that the rubric penalizes.
