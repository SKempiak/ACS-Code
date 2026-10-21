# Project 1 — SIMD Advantage Profiling

Quantify scalar vs. SIMD speedup for simple numeric kernels, and explain when vectorization helps,
when its gains compress, and when it fails. Required experiments are single-threaded.

## Files

| File | Purpose |
|---|---|
| `include/kernels.h` | Declarations for the kernels under test and their reference versions |
| `src/kernels.c` | Kernels under test, compiled once per build variant |
| `src/reference.c` | Simple reference implementations for correctness validation |
| `src/main.c` | Benchmark driver: configuration, data setup, validation, timing, raw output (`--counters` adds hardware-counter columns) |
| `src/ceilings.c` | Roofline ceilings, independent of the kernels: FMA/mul+add peak per ISA and STREAM-style read/copy/triad bandwidth per cache level (`build/ceilings/ceilings`) |
| `include/perfctr.h`, `src/perfctr.c` | User-space hardware counters via `perf_event_open` (no `perf`, no root; NA when unavailable) |
| `scripts/run.sh` | Runs each experiment below, plus `ceilings` and `derive` |
| `scripts/speedup_iqr.awk` | Adds speedup error-bar bounds (`speedup_q25/_q75`) to processed CSVs |
| `scripts/roofline.sh`, `scripts/tables.sh` | Derive roofline points/roofs and report tables from processed CSVs (no measuring) |
| `scripts/validate.sh` | Correctness checks (`make test`) |
| `scripts/verify_vectorization.sh` | Vectorization evidence (`make report`) |
| `Makefile` | Build variants: scalar, autovec, native (flags are TODO) |

## Kernels (choose at least three)

- SAXPY/AXPY: `y = a*x + y`
- Dot product: `s = sum(x[i] * y[i])`
- Elementwise multiply: `z[i] = x[i] * y[i]`
- 1D three-point stencil: `y[i] = a*x[i-1] + b*x[i] + c*x[i+1]`

## Knobs

- **Data type:** float32 vs. float64 (optionally int32)
- **Alignment and tail:** aligned arrays vs. arrays offset from a vector/cache-line boundary; N with and without a vector-width remainder
- **Access pattern:** unit stride vs. stride 2, 4, 8, or gather-style indices
- **Working-set size:** N across L1, L2, LLC and DRAM
- **Compiler / ISA:** scalar-only, default auto-vectorized, CPU-targeted widest vectors

## Required experiments

| `run.sh` experiment | What to show | Report section |
|---|---|---|
| `baseline` | Scalar vs. auto-vectorized for each kernel across working-set sizes; speedup and throughput | Baseline |
| `locality` | One kernel across cache levels; mark where SIMD gains compress as it becomes memory-bound | Locality |
| `alignment` | Cost of misalignment and tail handling (prologue/epilogue, unaligned loads, masking) | Alignment & tail |
| `stride` | How non-unit stride or gather lowers effective bandwidth and SIMD efficiency | Stride & gather |
| `dtype` | float32 vs. float64, explained by lane count, arithmetic intensity and operation cost | Data type |
| `make report` | Short compiler-report or disassembly evidence that SIMD happened | Vectorization verification |
| — | Roofline for at least one kernel from measured memory bandwidth and estimated peak FLOP rate | Roofline |
| `negative` | A loop that looks SIMD-friendly but isn't vectorized, or one that vectorizes but gains little because memory bandwidth dominates | Negative case |

**Metrics:** runtime, GFLOP/s or GiB/s, cycles (or time) per element.

**Tools:** GCC/Clang with exact versions and flags, vectorization reports or targeted disassembly, and `perf` counters (recommended).

## Deliverables

- Code, build and run scripts, raw and processed data
- Methodology:
  - CPU model and ISA; compiler and flags; OS
  - frequency policy; SMT state
  - timing method; repetitions; data initialization
- Plots and tables with units, legends and error bars
- Short report connecting results to cache locality, vector width, arithmetic intensity, memory bandwidth, and anomalies

## Rubric (110 points)

| Category | Points |
|---|---|
| Baseline, correctness, reproducibility | 15 |
| Vectorization verification | 15 |
| Locality and memory-bound analysis | 20 |
| Alignment, tail, stride/gather studies | 20 |
| Roofline and quantitative insight | 20 |
| AI-use transparency and failure case | 10 |
| Report quality | 10 |
