/*
 * main.c — benchmark driver for the SIMD kernels (Project 1).
 *
 * TODO:
 *   - Take the configuration for one run: kernel, data type, N, alignment/offset,
 *     stride or gather pattern, repetitions.
 *   - Allocate and initialize input data (document how, in the report).
 *   - Validate the kernel's output against the reference before timing it.
 *   - Time the kernel with a reliable timer; repeat and keep every repetition.
 *   - Write raw results with enough metadata to reproduce the run (build variant,
 *     compiler and flags, kernel, data type, N, alignment, stride).
 *   - Report runtime, throughput (GFLOP/s or GiB/s) and cycles or time per element.
 */
