# Code (all projects)

Code, scripts and data for the ECSE 4320/6320 Advanced Computer Systems class-wide projects
(due October 23, 2026, after a one-week extension). Each project's code lives in `<project>/code/` and its report in `<project>/latex/`;
this folder, `common/code/`, holds the code they share.

All three projects are implemented: benchmark sources, `code/scripts/run.sh` experiment drivers,
`make test` validation, and the raw and processed data used by each report. Each project README
lists its required experiments and rubric.

| Project | Directory |
|---|---|
| 1. SIMD Advantage Profiling | [`SIMD_Advantage_Profiling/code/`](../../SIMD_Advantage_Profiling/code/) |
| 2. Cache & Memory Performance Profiling | [`Cache_and_Memory_Performance_Profiling/code/`](../../Cache_and_Memory_Performance_Profiling/code/) |
| 3. SSD Performance Profiling | [`SSD_Performance_Profiling/code/`](../../SSD_Performance_Profiling/code/) |

## Layout

```
common/code/
  include/ src/      C code shared by more than one project
  tools/summarize.c  raw measurements -> processed data
  scripts/
    collect_env.sh   record the measurement environment
    sync_data.sh     copy processed data into <project>/latex/data/
  env/               saved hardware details (dmidecode output)
<project>/code/
  README.md          required experiments, knobs and deliverables
  Makefile
  include/ src/      C sources (projects 1 and 2)
  fio/               FIO job files (project 3)
  scripts/           run, validation and helper scripts
  data/raw/          raw measurements (committed)
  data/processed/    processed data read by the report's figures
AI_USE_LOG.md        running log for the AI-use note (repository root)
```

## Building

From the repository root:

```bash
make                                   # every C project
make tools                             # common/code/build/tools/summarize
make -C SIMD_Advantage_Profiling/code  # one project
make CC=clang                          # another compiler
make clean
```

Each project builds to working binaries; see the project README for its run and test targets.

Plots are drawn in the LaTeX reports with pgfplots, directly from the processed CSVs (copied to `<project>/latex/data/`). There are no
separate plotting scripts.

In VS Code, open the repository root (settings in `.vscode/`). Build tasks are under **Terminal → Run Build Task**.

## Common requirements (all projects)

- [x] **AI-use note:** tools used, what they helped generate, and what was independently modified, tested or rejected (keep [`AI_USE_LOG.md`](../../AI_USE_LOG.md) current)
- [x] **Reproducible repository:** source, build scripts, run scripts, raw data, processed data, README
- [x] **Hypothesis before each experiment:** the expected trend and why
- [x] **Correctness validation:** compare against a simple reference implementation or known sanity checks
- [x] **Measurement discipline:** record hardware, OS, compiler/tool versions, frequency governor, SMT state, pinning/isolation, repetitions, and error bars where feasible
- [x] **Negative / failure case:** at least one experiment where the technique stops helping or a naive benchmark misleads
- [x] **Honest anomalies:** unexpected results discussed with plausible hypotheses
- [ ] *Optional GPU extension:* CPU vs. GPU with kernel-only and end-to-end (including transfer) times
