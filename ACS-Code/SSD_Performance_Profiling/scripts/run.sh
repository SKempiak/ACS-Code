#!/usr/bin/env bash
# run.sh — experiment driver for Project 3.
#
# TODO: run scripts/safety.sh first, then one entry point per required experiment. Each
# writes FIO's raw output, the environment (../scripts/collect_env.sh), SSD and filesystem
# details and SMART snapshots to data/raw/<experiment>/<timestamp>/, and processed results
# to data/processed/<experiment>.csv:
#   precondition   fill + sustained writes to steady state
#   zero_queue     QD=1: 4 KiB random read/write, 128 KiB sequential read/write
#   block_size     4 KiB .. 256 KiB (512 KiB / 1 MiB sequential), random and sequential
#   rw_mix         100% read, 100% write, 70/30, 50/50
#   queue_depth    iodepth / numjobs sweep (knee, Little's Law)
#   tail           p50 / p95 / p99 / p99.9 at mid and near-knee queue depth
#   device_state   burst vs steady state, temperature
#   pitfall        the misleading-setup demonstration
# Repeat every configuration.
