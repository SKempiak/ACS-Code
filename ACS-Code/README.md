# ACS-Code

Code, scripts and data for the ECSE 4320/6320 Advanced Computer Systems class-wide projects
(due October 16, 2026). The reports live in [ACS-Latex](https://github.com/SKempiak/ACS-Latex).

This repository is a **template**. The folder structure, Makefiles and file headers are in place;
every source file and script is a TODO.

| Project | Directory |
|---|---|
| 1. SIMD Advantage Profiling | [`SIMD_Advantage_Profiling/`](SIMD_Advantage_Profiling/) |
| 2. Cache & Memory Performance Profiling | [`Cache_and_Memory_Performance_Profiling/`](Cache_and_Memory_Performance_Profiling/) |
| 3. SSD Performance Profiling | [`SSD_Performance_Profiling/`](SSD_Performance_Profiling/) |

## Layout

```
common/              C code shared by more than one project
tools/summarize.c    raw measurements -> processed data
scripts/
  collect_env.sh     record the measurement environment
  sync_data.sh       copy processed data into ACS-Latex
<project>/
  README.md          required experiments, knobs and deliverables
  Makefile
  include/ src/      C sources (projects 1 and 2)
  fio/               FIO job files (project 3)
  scripts/           run, validation and helper scripts
  data/raw/          raw measurements (committed)
  data/processed/    processed data read by the report's figures
AI_USE_LOG.md        running log for the AI-use note
```

## Building

```bash
make                                   # every C project
make -C SIMD_Advantage_Profiling       # one project
make CC=clang                          # another compiler
make clean
```

Linking fails until each program has a `main()`.

Plots are drawn in the LaTeX reports with pgfplots, directly from `data/processed/`. There are no
separate plotting scripts.

In VS Code, open `../ACS.code-workspace`. Build tasks are under **Terminal → Run Build Task**.

## Common requirements (all projects)

- [ ] **AI-use note:** tools used, what they helped generate, and what was independently modified, tested or rejected (keep [`AI_USE_LOG.md`](AI_USE_LOG.md) current)
- [ ] **Reproducible repository:** source, build scripts, run scripts, raw data, processed data, README
- [ ] **Hypothesis before each experiment:** the expected trend and why
- [ ] **Correctness validation:** compare against a simple reference implementation or known sanity checks
- [ ] **Measurement discipline:** record hardware, OS, compiler/tool versions, frequency governor, SMT state, pinning/isolation, repetitions, and error bars where feasible
- [ ] **Negative / failure case:** at least one experiment where the technique stops helping or a naive benchmark misleads
- [ ] **Honest anomalies:** unexpected results discussed with plausible hypotheses
- [ ] *Optional GPU extension:* CPU vs. GPU with kernel-only and end-to-end (including transfer) times
