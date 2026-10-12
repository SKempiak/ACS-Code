/*
 * mem_latency.c — zero-queue memory access latency (Project 2).
 *
 * TODO:
 *   - Single thread, pinned; working-set size chosen to sit in L1, L2, LLC or DRAM.
 *   - Make sure the data really resides in the level being measured, and keep page
 *     faults and warm-up out of the timed region.
 *   - Time many accesses and report per-access latency with units; account for timer
 *     and loop overhead.
 *   - Record every repetition with its configuration (size, pattern, page size, CPU).
 */
