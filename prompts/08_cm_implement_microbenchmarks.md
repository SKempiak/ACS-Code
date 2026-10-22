# Prompt 09 — Implement the cache & memory microbenchmarks

I'm doing the Cache & Memory Performance Profiling project. In
`ACS-Code/Cache_and_Memory_Performance_Profiling/src/` there are three files that are just
TODO comments: `mem_latency.c`, `mem_bandwidth.c` and `kernel_miss.c`. The recommended tools
(Intel MLC, `perf`) aren't installed on my machine, so I need to measure latency and
bandwidth with my own benchmarks.

Please implement them, reusing the shared harness in `ACS-Code/common` (monotonic timer,
aligned allocation, CPU pinning):

- `mem_latency.c`: zero-queue latency by pointer-chasing. Build a single random permutation
  ring (one node per 64 B cache line) over a working set of a given size, so each load
  depends on the previous one and exactly one request is outstanding. It must **defeat the
  prefetcher** (randomized chase, not a sequential stride), pre-fault and warm up outside the
  timed region, and report ns/access plus a cycle estimate. Sweep the working-set size from
  L1-resident to DRAM-resident.
- `mem_bandwidth.c`: streaming bandwidth with `T` pinned threads — read, write, copy, triad
  and a read/write-mix mode — over a DRAM-resident region; report GiB/s.
- `kernel_miss.c`: a SAXPY-style loop whose footprint and access order vary, to correlate
  cache behaviour with runtime (it'll run under `perf stat` if that ever becomes available,
  otherwise just emit runtime).

Each binary should print raw per-repetition CSV rows (with a `--header` option) that
`tools/summarize` can reduce. Keep everything single-threaded unless I pass a thread count.

---
**What this demonstrates:** building honest measurement tools from scratch when the
"recommended" vendor tools are unavailable — and the key methodological point that a latency
benchmark must randomize its access pattern or the prefetcher turns it into a throughput test.
