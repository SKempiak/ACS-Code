#!/usr/bin/env bash
# fio_to_csv.sh — convert FIO results to CSV.
#
# TODO: from FIO's JSON output, extract per job and direction: the knobs (rw, bs, iodepth,
# numjobs, read/write mix), IOPS, throughput (MiB/s), mean latency, p50 / p95 / p99 / p99.9
# latency, and runtime.
