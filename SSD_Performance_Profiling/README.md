# Project 3 — SSD Performance Profiling

Characterize an NVMe SSD with FIO:
- QD=1 latency;
- block-size and read/write-mix effects;
- the throughput–latency knee as queue depth grows;
- tail latency and device state.

> **Data-loss warning.** Never benchmark a partition that holds valuable data. Use a dedicated
> empty partition, a raw device reserved for testing, or a large disposable file with direct I/O.

## Files

| File | Purpose |
|---|---|
| `fio/job.fio` | FIO job file(s) for the sweeps |
| `fio/precondition.fio` | Preconditioning before steady-state measurements |
| `scripts/run.sh` | Runs each experiment below |
| `scripts/safety.sh` | Guard against benchmarking the wrong target |
| `scripts/fio_to_csv.sh` | FIO output → CSV (IOPS, MiB/s, latency percentiles) |

**Tools:** FIO; optionally OS disk statistics and SMART/health tools (temperature, throttling,
write counts).

## Knobs

- **Block size:** 4, 16, 32, 64, 128, 256 KiB (optionally 512 KiB or 1 MiB sequential)
- **Access pattern:** sequential vs. random (keep random I/O block-aligned)
- **Read/write ratio:** 100% read, 100% write, 70/30, 50/50
- **Queue depth / parallelism:** iodepth and/or numjobs, e.g. 1 → 256
- **Data pattern:** incompressible vs. compressible, held constant and documented
- **Device state:** fresh/burst vs. steady state, temperature, SLC cache exhaustion, background garbage collection

## Required experiments

| `run.sh` experiment | What to show | Report section |
|---|---|---|
| `zero_queue` | QD=1 latency for 4 KiB random read/write and 128 KiB sequential read/write, with p95/p99 | Zero-queue baselines |
| `block_size` | Throughput and latency from the same runs, random and sequential | Block-size sweep |
| `rw_mix` | Read/write mix at a fixed block size and pattern | Read/write mix |
| `queue_depth` | One throughput-vs-latency curve; the knee; Little's Law | Queue-depth sweep |
| `tail` | Tail latency at a mid queue depth and near the knee | Tail latency |
| `device_state` | Working-set/LBA range and burst vs. steady state | Device state |
| `pitfall` | One misleading setup: buffered I/O and page cache, wrong effective queue depth, insufficient preconditioning, or thermal throttling | Pitfall |

## Deliverables

- FIO configs, scripts, raw results, parsed data
- Methodology:
  - SSD model and interface
  - filesystem vs. raw device, direct I/O usage
  - capacity / range used
  - OS/kernel, CPU, temperature
- Plots and tables with units, error bars, and clear fixed vs. varied knobs
- Analysis grounded in queueing theory, controller behavior, interface ceilings and tail latency

## Rubric (185 points)

| Category | Points |
|---|---|
| Safety and zero-queue baselines | 30 |
| Block-size and pattern sweeps | 35 |
| Read/write and queue-depth analysis | 40 |
| Tail latency and device state | 25 |
| Reproducibility and data hygiene | 25 |
| AI-use transparency and pitfall analysis | 15 |
| Report quality | 15 |
