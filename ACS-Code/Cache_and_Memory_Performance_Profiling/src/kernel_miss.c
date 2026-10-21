/*
 * kernel_miss.c — simple loop kernel for cache- and TLB-miss correlation (P2).
 *
 * Runs SAXPY (y[i] = a*x[i] + y[i]) or MUL (z[i] = x[i]*y[i]) over a chosen
 * footprint and access order and reports runtime, ns/element and — with
 * --counters — user-space hardware counters per element read through
 * perf_event_open(2) (the `perf` tool is not installed and perf_event_paranoid=2,
 * but a process may count its own user-mode events):
 *   cycles, instructions, L1D read misses, LLC read references, LLC read misses,
 *   dTLB read misses (completed page walks on this core).
 * Sweeping the footprint makes the L1/L2/L3/DRAM steps visible in both runtime
 * and miss counts; switching between 4 KiB and 2 MiB pages with a random order
 * exposes the TLB-miss cost.
 *
 *   --kernel  saxpy | mul
 *   --n       element count (footprint = N * 8 B * #arrays)
 *   --pattern sequential | random   (random = shuffled index, one touch/element)
 *   --pages   4k | huge  (explicit madvise before first touch; the AnonHugePages
 *                         actually granted is read from /proc/self/smaps_rollup)
 *   --counters           add per-element counter columns (nan if unavailable)
 */
#define _GNU_SOURCE
#include "common.h"
#include "memprof.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int mul, random_order;
    size_t n;
    double *x, *y, *z;
    const uint32_t *idx;
} kern_t;

__attribute__((noinline))
static void run_once(const kern_t *k) {
    const double aa = 0.5;
    double *x = k->x, *y = k->y, *z = k->z;
    size_t n = k->n;
    if (k->mul) {
        if (k->random_order) for (size_t i = 0; i < n; i++) { size_t j = k->idx[i]; z[j] = x[j] * y[j]; }
        else                 for (size_t i = 0; i < n; i++) z[i] = x[i] * y[i];
    } else {
        if (k->random_order) for (size_t i = 0; i < n; i++) { size_t j = k->idx[i]; y[j] = aa * x[j] + y[j]; }
        else                 for (size_t i = 0; i < n; i++) y[i] = aa * x[i] + y[i];
    }
}

int main(int argc, char **argv) {
    size_t n = 1 << 16;
    int reps = 8, warmup = 2, cpu = -1, want_header = 0, use_huge = 0, random_order = 0;
    int counters = 0;
    double min_ms = 50.0;
    unsigned seed = 99u;
    const char *kernel = "saxpy", *experiment = "cache_miss";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc && strcmp(a, "--header") && strcmp(a, "--counters")) {
            fprintf(stderr, "missing value for %s\n", a); return 2;
        }
#define NEXT (argv[++i])
        if      (!strcmp(a, "--n"))       n = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--kernel"))  kernel = NEXT;
        else if (!strcmp(a, "--pattern")) random_order = !strcmp(NEXT, "random");
        else if (!strcmp(a, "--pages"))   use_huge = mp_parse_pages(NEXT);
        else if (!strcmp(a, "--counters")) counters = 1;
        else if (!strcmp(a, "--reps"))    reps = atoi(NEXT);
        else if (!strcmp(a, "--min-ms"))  min_ms = atof(NEXT);
        else if (!strcmp(a, "--warmup"))  warmup = atoi(NEXT);
        else if (!strcmp(a, "--cpu"))     cpu = atoi(NEXT);
        else if (!strcmp(a, "--seed"))    seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--header"))  want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (cpu >= 0 && acs_pin_cpu(cpu) != 0)
        fprintf(stderr, "warning: could not pin to CPU %d\n", cpu);
    if (n < 16) n = 16;

    kern_t k = {0};
    k.mul = !strcmp(kernel, "mul");
    k.random_order = random_order;
    k.n = n;
    int narr = k.mul ? 3 : 2;

    /* 2 MiB-aligned mappings; page size decided by madvise before first touch */
    mp_buf xb = mp_alloc(n * sizeof(double), use_huge);
    mp_buf yb = mp_alloc(n * sizeof(double), use_huge);
    mp_buf zb = {0, 0, 0};
    k.x = xb.ptr; k.y = yb.ptr;
    if (k.mul) { zb = mp_alloc(n * sizeof(double), use_huge); k.z = zb.ptr; memset(k.z, 0, n * sizeof(double)); }
    unsigned s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        k.x[i] = (double)((s >> 8) & 0xffff) / 65536.0 - 0.5;
        k.y[i] = 0.25;
    }

    mp_buf ib = {0, 0, 0};
    if (random_order) {
        ib = mp_alloc(n * sizeof(uint32_t), use_huge);
        uint32_t *idx = ib.ptr;
        for (size_t i = 0; i < n; i++) idx[i] = (uint32_t)i;
        s = seed ^ 0x51edu;
        for (size_t i = n - 1; i > 0; i--) {
            s = s * 1664525u + 1013904223u;
            size_t j = s % (i + 1);
            uint32_t t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        k.idx = idx;
    }
    long ahp = mp_anon_thp_kib();
    double ghz = mp_measure_ghz();

    for (int w = 0; w < warmup; w++) { run_once(&k); acs_consume_f64(k.y[0]); }

    size_t iters = 1;
    for (;;) {
        double t0 = acs_now_sec();
        for (size_t it = 0; it < iters; it++) run_once(&k);
        double dt = acs_now_sec() - t0;
        acs_consume_f64(k.y[0]);
        if (dt >= min_ms / 1000.0 || iters >= (1u << 28)) break;
        iters *= 2;
    }

    mp_ctr ctr;
    mp_ctr_open(&ctr, counters);

    if (want_header) {
        printf("experiment,kernel,pattern,pages,n,bytes,ghz,anon_thp_kib,rep,iters,time_s,"
               "ns_per_elem,gflops");
        mp_ctr_header("pe");
        printf("\n");
    }

    double fpe = k.mul ? 1.0 : 2.0;
    for (int r = 0; r < reps; r++) {
        double cv[MP_NCTR], cover;
        mp_ctr_start(&ctr);
        double t0 = acs_now_sec();
        for (size_t it = 0; it < iters; it++) run_once(&k);
        double dt = acs_now_sec() - t0;
        mp_ctr_stop(&ctr, cv, &cover);
        acs_consume_f64(k.y[0]);
        double per_call = dt / (double)iters;
        double nspe = per_call * 1e9 / (double)n;
        double gflops = fpe * (double)n / per_call / 1e9;
        printf("%s,%s,%s,%s,%zu,%zu,%.3f,%ld,%d,%zu,%.9e,%.6e,%.6e",
               experiment, k.mul ? "mul" : "saxpy", random_order ? "random" : "sequential",
               use_huge ? "huge" : "4k", n, n * sizeof(double) * (size_t)narr, ghz, ahp, r, iters,
               per_call, nspe, gflops);
        mp_ctr_print(cv, cover, (double)n * (double)iters);
        printf("\n");
    }
    mp_ctr_close(&ctr);
    mp_free(xb); mp_free(yb); mp_free(zb); mp_free(ib);
    return 0;
}
