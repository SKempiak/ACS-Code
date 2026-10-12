/*
 * kernel_miss.c — loop kernel for cache- and TLB-miss correlation (Project 2).
 *
 * TODO:
 *   - A simple kernel such as z[i] = x[i] * y[i] or y[i] = a*x[i] + y[i].
 *   - Knobs: footprint (N), access order, 4 KiB pages vs. huge pages.
 *   - Run under perf (cache misses, TLB misses, cycles, instructions) and record runtime
 *     so the two can be correlated.
 */
