#!/usr/bin/env bash
# run.sh — experiment driver for Project 2.
#
# TODO: one entry point per required experiment. Each writes raw results plus the
# environment (../scripts/collect_env.sh) to data/raw/<experiment>/<timestamp>/ and
# processed results to data/processed/<experiment>.csv:
#   zero_queue    per-level latency (L1, L2, LLC, DRAM)
#   pattern       sequential vs random x ~64/256/1024-byte granularity
#   rw_mix        100% read, 100% write, 70/30, 50/50
#   intensity     throughput vs latency as concurrency grows (knee, Little's Law)
#   working_set   L1-resident to DRAM-resident sizes
#   cache_miss    footprint / access pattern vs perf counters and runtime
#   tlb           4 KiB pages vs huge pages
#   pitfall       the benchmark-pitfall demonstration
#   mlc           Intel MLC runs (keep raw output)
# Pin threads, keep the governor and SMT state fixed, and record repetitions.
