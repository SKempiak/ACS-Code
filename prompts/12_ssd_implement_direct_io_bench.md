# Prompt 14 — Implement a direct-I/O storage benchmark

I'm doing the SSD Performance Profiling project. The project recommends FIO, but FIO isn't
installed on my machine and I can't install it (no sudo). I still need real numbers, so I want
a small C benchmark that does the same job for the required experiments.

In `ACS-Code/SSD_Performance_Profiling/src/`, please write `blkbench.c` that issues I/O to a
**disposable file** (never a device or partition) using `O_DIRECT` so the page cache is
bypassed, with an asynchronous engine (libaio or io_uring) so it can keep a real queue depth
in flight. It needs flags for: block size, queue depth (`--qd`), pattern (`rand`/`seq`),
read/write mix, a measured run time, repetitions, an LBA-range/span limit, and a `--buffered`
option that deliberately *keeps* the page cache (for the pitfall experiment). It should report
IOPS, MiB/s, mean latency and the p50/p95/p99/p99.9 completion-latency percentiles as CSV rows
that `tools/summarize` can reduce. Add a `--precondition` mode that does a full sequential
O_DIRECT write pass first.

Keep random offsets aligned to the block size, and make the reported latency the completion
latency of each I/O.

---
**What this demonstrates:** producing honest, queue-aware storage measurements without the
recommended vendor tool — including real asynchronous queue depth and tail-latency
percentiles — rather than giving up or faking FIO output.
