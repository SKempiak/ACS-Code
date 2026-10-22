# ACS-Code

Code, scripts and data for the ECSE 4320/6320 Advanced Computer Systems class-wide projects
(due October 23, 2026, after a one-week extension). The reports live in [`../ACS-Latex`](../ACS-Latex) in this same repository.

All three projects are implemented: benchmark sources, `scripts/run.sh` experiment drivers,
`make test` validation, and the raw and processed data used by each report. Each project README
lists its required experiments and rubric.

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

Each project builds to working binaries; see the project README for its run and test targets.

Plots are drawn in the LaTeX reports with pgfplots, directly from `data/processed/`. There are no
separate plotting scripts.

In VS Code, open `../ACS.code-workspace`. Build tasks are under **Terminal → Run Build Task**.

## Common requirements (all projects)

- [x] **AI-use note:** tools used, what they helped generate, and what was independently modified, tested or rejected (keep [`AI_USE_LOG.md`](AI_USE_LOG.md) current)
- [x] **Reproducible repository:** source, build scripts, run scripts, raw data, processed data, README
- [x] **Hypothesis before each experiment:** the expected trend and why
- [x] **Correctness validation:** compare against a simple reference implementation or known sanity checks
- [x] **Measurement discipline:** record hardware, OS, compiler/tool versions, frequency governor, SMT state, pinning/isolation, repetitions, and error bars where feasible
- [x] **Negative / failure case:** at least one experiment where the technique stops helping or a naive benchmark misleads
- [x] **Honest anomalies:** unexpected results discussed with plausible hypotheses
- [ ] *Optional GPU extension:* CPU vs. GPU with kernel-only and end-to-end (including transfer) times
