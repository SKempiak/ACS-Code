# ACS — Advanced Computer Systems Class-wide Projects

Code, measured data and reports for the three ECSE 4320/6320 (Fall 2026) class-wide projects.
Every number in the reports comes from a measurement committed in this repository, and each
report's appendix gives the commands that reproduce it.

| Project | What it measures | Report | Project folder (`code/` + `latex/`) |
|---|---|---|---|
| 1. SIMD Advantage Profiling | Scalar vs. auto-vectorized kernels (SAXPY, dot product, elementwise multiply, 3-point stencil) across data types, sizes, alignment and stride; roofline analysis | [PDF](SIMD_Advantage_Profiling/latex/SIMD_Advantage_Profiling.pdf) | [`SIMD_Advantage_Profiling/`](SIMD_Advantage_Profiling/) |
| 2. Cache & Memory Performance Profiling | Latency and bandwidth of L1, L2, L3 and DRAM; access pattern, read/write mix, TLB and huge pages, loaded latency and Little's Law; cross-checked with Intel MLC | [PDF](Cache_and_Memory_Performance_Profiling/latex/Cache_and_Memory_Performance_Profiling.pdf) | [`Cache_and_Memory_Performance_Profiling/`](Cache_and_Memory_Performance_Profiling/) |
| 3. SSD Performance Profiling | NVMe latency, IOPS and throughput vs. block size, read/write mix and queue depth; tail latency, working set and SLC-cache behaviour; cross-checked with FIO | [PDF](SSD_Performance_Profiling/latex/SSD_Performance_Profiling.pdf) | [`SSD_Performance_Profiling/`](SSD_Performance_Profiling/) |

## Test machine

Intel Core i9-10900F (10 cores, SMT off, turbo off, `performance` governor), 2 × 32 GiB DDR4,
Micron 2210 512 GB QLC NVMe SSD, Arch Linux (kernel 7.2.9), GCC 16.2.1, FIO 3.42.
The full environment table is in each report.

## Where to find what

This README is an overview. The READMEs below hold the details:

| README | Contents |
|---|---|
| [`common/code/README.md`](common/code/README.md) | Code layout, building, shared tools, the requirements common to all projects |
| `<project>/code/README.md` | That project's experiments, run commands, knobs, required system settings and rubric |
| [`common/latex/README.md`](common/latex/README.md) | Report layout, draft vs. final builds, how figures are plotted from the CSVs |
| [`AI_USE_LOG.md`](AI_USE_LOG.md) | Log of AI tool use for all three projects, summarized in each report's AI-use note |
| [`prompts/RESULTS.md`](prompts/RESULTS.md) | The prompts given to the AI coding agent and what each produced |

## Layout

```
<project>/
  code/       benchmark sources, run and validation scripts, raw and processed data
  latex/      LaTeX report and its PDF; figures are plotted directly from the processed CSVs
common/
  code/       C helpers, summarize tool, environment and data-sync scripts shared by all projects
  latex/      preamble, macros, environment table and bibliography shared by all reports
AI_USE_LOG.md AI-use log for all three projects
prompts/      prompts given to the AI coding agent, with RESULTS.md
Makefile      builds all code and reports
```

## Quick start

```bash
make                              # build every benchmark
make tools                        # build the summarize tool used by the run scripts
make -C <project>/code test       # run one project's validation tests
make final                        # rebuild all three reports in final mode
```

Timed runs need root-only settings (governor, turbo, SMT); each report's methodology section lists them.
The SSD benchmarks write only to disposable files under `ACS_SCRATCH` and refuse raw block
devices. Set `ACS_SCRATCH` to a directory on the drive under test; the default,
`SSD_Performance_Profiling/code/data/scratch/`, is wherever the repository lives.
