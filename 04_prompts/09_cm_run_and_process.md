# Prompt 09 — Wire up the experiment driver and data pipeline

The three cache/memory benchmarks build now. I need a repeatable experiment driver, like the
one the SIMD project has. In `ACS-Code/Cache_and_Memory_Performance_Profiling/scripts/`,
please write `run.sh` with one entry point per required experiment:

- `latency` — the working-set sweep (L1 → DRAM), random and sequential;
- `granularity` — bandwidth vs. stride/granularity (8 B … 1024 B), sequential and random;
- `rwmix` — 100% read, 70/30, 50/50, 100% write;
- `intensity` — bandwidth vs. thread count (1 … 10), for the throughput–latency knee;
- `cache_miss` and `tlb` — the kernel_miss correlations and the 4 KiB-vs-huge-page study;
- `pitfall` — the bandwidth-vs-working-set run for the negative case.

Each experiment should append per-repetition rows into
`data/raw/<exp>/<timestamp>/raw.csv`, snapshot the environment next to it with
`../../scripts/collect_env.sh`, then reduce the rows with `tools/summarize` into
`data/processed/<exp>.csv` — these processed files are what the LaTeX figures read directly.
Runs must be single-thread-pinned (honor a `CPU_PIN` env var) with a configurable `REPS`.
Also add a `validate.sh` that asserts the physically necessary orderings (L1 < L2 < L3 <
DRAM latency; cache bandwidth > DRAM bandwidth; multi-thread > single-thread) so a broken run
fails loudly.

---
**What this demonstrates:** reproducible measurement discipline — a sweep-driver that
captures raw data, the environment, and processed data together, plus sanity checks that
catch a physically impossible result before it reaches a plot.
