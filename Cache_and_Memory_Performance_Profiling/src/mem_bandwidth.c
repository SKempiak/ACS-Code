/*
 * mem_bandwidth.c — memory bandwidth and latency under load (Project 2).
 *
 * TODO:
 *   - Knobs: access pattern (sequential / random), granularity (~64 / 256 / 1024 bytes),
 *     read/write mix (100/0, 0/100, 70/30, 50/50), concurrent threads or outstanding
 *     requests, page size.
 *   - Report throughput (GiB/s, ops/s) and latency (mean and percentiles) per configuration.
 *   - Pin threads and record placement; repeat runs.
 *   - Produce what is needed to plot throughput vs. latency and check Little's Law.
 */
