# Prompt 03 — Write the benchmark driver

Write `src/main.c`, the driver for the SIMD benchmark. One invocation should measure one
configuration and print raw CSV rows (one per repetition) to stdout, so a run script can
sweep the knobs by calling it many times.

It needs to take, from the command line: which kernel, data type (f32/f64/i32), N,
alignment offset in bytes, access pattern (unit/stride/gather), stride, repetitions,
warm-up count, and which CPU to pin to. For each run it should allocate and initialize the
data deterministically, **validate the output against the reference before timing it**,
then time the kernel with a monotonic clock, repeating a calibrated batch so each timed
interval is long enough to dwarf the timer resolution. Report per-repetition time,
throughput (elements/s and GFLOP/s) and ns/element.

Please be careful about measurement discipline: warm up first, keep every repetition (I'll
compute median and IQR later), pin the thread, and above all make sure the compiler can't
delete the kernel as dead code — consume the result through a sink. Put reusable helpers
(timer, aligned allocation with an offset, CPU pinning, a consume/sink) in the shared
`common/` library.

---
**What this demonstrates:** measurement discipline — warm-up, repetition, pinning,
calibrated timing, and defeating dead-code elimination — which is exactly what separates a
credible benchmark from a plausible-looking but misleading one.
