# Project 2 — Cache & Memory Performance Profiling

Measure the L1/L2/L3/DRAM hierarchy and explain how locality, concurrency, cache misses and TLB
misses determine performance, using Little's Law and AMAT-style reasoning.

## Files

| File | Purpose |
|---|---|
| `src/mem_latency.c` | Zero-queue access latency for a working set placed in L1, L2, LLC or DRAM |
| `src/mem_bandwidth.c` | Bandwidth and latency vs. access pattern, granularity, read/write mix and concurrency |
| `src/kernel_miss.c` | Simple loop kernel for correlating cache/TLB misses with runtime |
| `scripts/run.sh` | Runs each experiment below |
| `Makefile` | Builds each program in `src/` |

**Tools:** Intel Memory Latency Checker (or equivalent), `perf`, simple loop kernels such as
`z[i] = x[i] * y[i]` or `y[i] = a*x[i] + y[i]`.

## Knobs

- **Access pattern:** sequential vs. random; granularity near 64 B, 256 B and 1024 B
- **Read/write ratio:** 100% read, 100% write, 70/30, 50/50
- **Access intensity:** outstanding requests or threads (loaded-latency sweeps)
- **Working-set size:** L1-resident through DRAM-resident
- **Page locality:** 4 KiB pages vs. huge pages

## Required experiments

| `run.sh` experiment | What to show | Report section |
|---|---|---|
| `zero_queue` | Per-level latency table with units (and CPU-cycle conversion) | Zero-queue baselines |
| `pattern` | Latency and bandwidth across sequential/random and granularity | Pattern & granularity |
| `rw_mix` | Throughput and latency for each read/write mix | Read/write mix |
| `intensity` | Throughput vs. latency; the knee; Little's Law | Intensity knee |
| `working_set` | L1/L2/LLC/DRAM transition regions | Working-set sweep |
| `cache_miss` | Footprint or access pattern vs. perf counters and runtime | Cache-miss impact |
| `tlb` | Page locality and huge pages vs. TLB misses | TLB-miss impact |
| `pitfall` | One benchmark pitfall (cache reuse instead of DRAM, unpinned threads, frequency scaling) | Pitfall |
| `mlc` | Intel MLC runs as a cross-check | Validation |

## Deliverables

- Scripts and commands, raw data, processed data
- System configuration:
  - CPU, memory, OS/kernel, tool versions
  - governor / frequency policy, SMT state
  - pinning, NUMA placement
- Plots and tables with units, repeated trials and error bars
- Analysis tied to latency, bandwidth, concurrency, cache/TLB counters, AMAT and Little's Law

## Rubric (185 points)

| Category | Points |
|---|---|
| Zero-queue baselines | 25 |
| Pattern / granularity / read-write sweeps | 35 |
| Throughput–latency knee | 35 |
| Working-set / cache / TLB analysis | 35 |
| Experimental rigor | 25 |
| AI-use transparency and pitfall analysis | 15 |
| Report quality | 15 |
