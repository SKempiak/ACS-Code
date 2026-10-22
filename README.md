# ACS — Advanced Computer Systems Class-wide Projects

Code, measured data and reports for the three ECSE 4320/6320 (Fall 2026) class-wide projects.
Every number in the reports comes from a measurement committed in this repository, and each
report's appendix gives the commands that reproduce it.

| Project | What it measures | Report | Code and data |
|---|---|---|---|
| 1. SIMD Advantage Profiling | Scalar vs. auto-vectorized kernels (SAXPY, dot product, elementwise multiply, 3-point stencil) across data types, sizes, alignment and stride; roofline analysis | [PDF](ACS-Latex/SIMD_Advantage_Profiling/SIMD_Advantage_Profiling.pdf) | [`ACS-Code/SIMD_Advantage_Profiling/`](ACS-Code/SIMD_Advantage_Profiling/) |
| 2. Cache & Memory Performance Profiling | Latency and bandwidth of L1, L2, L3 and DRAM; access pattern, read/write mix, TLB and huge pages, loaded latency and Little's Law; cross-checked with Intel MLC | [PDF](ACS-Latex/Cache_and_Memory_Performance_Profiling/Cache_and_Memory_Performance_Profiling.pdf) | [`ACS-Code/Cache_and_Memory_Performance_Profiling/`](ACS-Code/Cache_and_Memory_Performance_Profiling/) |
| 3. SSD Performance Profiling | NVMe latency, IOPS and throughput vs. block size, read/write mix and queue depth; tail latency, working set and SLC-cache behaviour; cross-checked with FIO | [PDF](ACS-Latex/SSD_Performance_Profiling/SSD_Performance_Profiling.pdf) | [`ACS-Code/SSD_Performance_Profiling/`](ACS-Code/SSD_Performance_Profiling/) |

## Test machine

Intel Core i9-10900F (10 cores, SMT off, turbo off, `performance` governor), 2 × 32 GiB DDR4,
Micron 2210 512 GB QLC NVMe SSD, Arch Linux (kernel 7.2.9), GCC 16.2.1, FIO 3.42.
The full environment table is in each report.

## Where to find what

This README is an overview. The READMEs below hold the details:

| README | Contents |
|---|---|
| [`ACS-Code/README.md`](ACS-Code/README.md) | Code layout, building, shared tools, the requirements common to all projects |
| `ACS-Code/<project>/README.md` | That project's experiments, run commands, knobs, required system settings and rubric |
| [`ACS-Latex/README.md`](ACS-Latex/README.md) | Report layout, draft vs. final builds, how figures are plotted from the CSVs |
| [`ACS-Code/AI_USE_LOG.md`](ACS-Code/AI_USE_LOG.md) | Log of AI tool use for all three projects, summarized in each report's AI-use note |
| [`prompts/RESULTS.md`](prompts/RESULTS.md) | The prompts given to the AI coding agent and what each produced |

## Layout

```
ACS-Code/     benchmark sources, run and validation scripts, raw and processed data
ACS-Latex/    LaTeX reports; figures are plotted directly from the processed CSVs
prompts/      prompts given to the AI coding agent, with RESULTS.md
```

## Quick start

```bash
make -C ACS-Code                  # build every benchmark
make -C ACS-Code/<project> test   # run one project's validation tests
make -C ACS-Latex final           # rebuild all three reports in final mode
```

Timed runs need root-only settings (governor, turbo, SMT); each report's methodology section lists them.
The SSD benchmarks write only to disposable files under `ACS_SCRATCH` and refuse raw block
devices. Set `ACS_SCRATCH` to a directory on the drive under test; the default,
`ACS-Code/SSD_Performance_Profiling/data/scratch/`, is wherever the repository lives.
