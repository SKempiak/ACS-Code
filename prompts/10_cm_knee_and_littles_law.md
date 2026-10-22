# Prompt 11 — Intensity knee and Little's Law write-up

I have the intensity sweep data (`data/processed/intensity.csv`: delivered bandwidth vs.
thread count) and the zero-queue latency table. For the report's "Throughput–latency knee"
section (worth 35 points), help me turn this into a proper analysis, not just a plot.

Specifically: identify the knee in the bandwidth-vs-concurrency curve and say where it is;
then apply Little's Law to explain *why* a single core can't saturate the memory controller.
Use $L = \lambda W$ with $\lambda$ = delivered bandwidth / 64 B line size and $W$ = the
measured zero-queue random DRAM latency, and build a small table of outstanding-request count
$L$ per thread count. Explain the connection to the ~10 fill buffers (line-fill/MSHRs) a
single core has.

Be careful and honest about one thing: the streaming kernel runs under the prefetcher, so its
effective loaded latency is below the zero-queue random figure — so the $L$ column is an
upper-bound estimate of required concurrency, not an exact occupancy. Say that explicitly
rather than pretending the numbers are exact.

---
**What this demonstrates:** architectural interpretation using queueing theory — connecting a
measured knee to memory-level parallelism via Little's Law, while being candid about the
approximation the model rests on.
