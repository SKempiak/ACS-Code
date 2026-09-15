#!/usr/bin/env bash
# run.sh — experiment driver for Project 1.
#
# TODO: one entry point per required experiment. Each writes raw results plus the
# environment (../scripts/collect_env.sh) to data/raw/<experiment>/<timestamp>/ and
# processed results to data/processed/<experiment>.csv:
#   baseline    scalar vs auto-vectorized for every kernel across working-set sizes
#   locality    one kernel across L1 / L2 / LLC / DRAM sizes
#   alignment   aligned vs offset arrays; N with and without vector-width remainders
#   stride      unit stride vs stride 2/4/8 and gather-style indexing
#   dtype       float32 vs float64 (optionally int32)
#   negative    the negative example
# Keep runs single-threaded and pinned, and record repetitions.
