# Prompt 01 — Implement the kernels and references

I'm doing the SIMD Advantage Profiling project for my Advanced Computer Systems class.
In `ACS-Code/SIMD_Advantage_Profiling/` there's a skeleton with `include/kernels.h`,
`src/kernels.c` and `src/reference.c` that are all just TODO comments right now.

Please implement four numeric kernels — SAXPY (`y = a*x + y`), dot product
(`s = sum(x[i]*y[i])`), elementwise multiply (`z[i] = x[i]*y[i]`) and a 1-D 3-point
stencil (`y[i] = a*x[i-1] + b*x[i] + c*x[i+1]`) — in both float32 and float64, plus an
int32 elementwise multiply. I also need strided and gather variants of SAXPY for the
access-pattern study later. Write the loops in the simplest form that the compiler can
auto-vectorize (unit stride, running-sum reductions, no pointer-aliasing tricks) so that
the *build flags*, not the source, decide whether they vectorize.

Then put matching reference versions in `src/reference.c` with the same math — these are
the gold implementations I'll validate against, so keep them plain and scalar.

Keep the declarations in `include/kernels.h` consistent with both files.

---
**What this demonstrates:** turning a written spec into correct, reference-checkable code,
and deliberately keeping the kernel source neutral so that vectorization is controlled by
compiler flags rather than hand-written intrinsics.
