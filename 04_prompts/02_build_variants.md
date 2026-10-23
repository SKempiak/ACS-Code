# Prompt 02 — Fill in the build variants

The `Makefile` in `ACS-Code/SIMD_Advantage_Profiling/` has three build variants —
`scalar`, `autovec`, `native` — but the `CFLAGS_*` are empty TODOs, and there's a comment
saying I need to decide which sources get the variant flags and which stay the same across
variants.

Please fill in the flags so that:
- `scalar` has optimization on but auto-vectorization off,
- `autovec` is the default auto-vectorized build,
- `native` targets the widest vector ISA of my actual CPU.

Explain in a sentence each why you chose those flags. Importantly, only the kernel
translation unit should get the per-variant flags — the timing harness and the reference
implementation must be compiled the same way in every variant, otherwise I'd be comparing
drivers instead of kernels. Make the reference compile with vectorization and FP
contraction off so it stays a trustworthy oracle. Also have the binary be able to print
which variant and flags it was built with (I'll cite that in the report).

---
**What this demonstrates:** controlling vectorization through compiler flags, documenting
each flag's purpose, and isolating the variable under test by keeping the measurement
harness identical across builds.
