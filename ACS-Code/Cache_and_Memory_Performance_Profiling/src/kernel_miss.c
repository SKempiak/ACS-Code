/*
 * kernel_miss.c — simple loop kernel for cache- and TLB-miss correlation (P2).
 *
 * Runs SAXPY (y[i] = a*x[i] + y[i]) over a chosen footprint and access order and
 * reports runtime and ns/element. Sweeping the footprint makes the L1/L2/L3/DRAM
 * cache-miss steps visible in runtime; switching between 4 KiB and transparent
 * huge pages, with a random access order that touches one element per page,
 * exposes the TLB-miss cost.
 *
 * The project spec recommends running this under perf for cache-miss and TLB-miss
 * counters. perf is NOT available on the test host (not installed;
 * perf_event_paranoid=2), so this program reports runtime only and the analysis
 * correlates runtime with footprint/page size rather than with hardware counters.
 * The command line is perf-ready: `perf stat -e cache-misses,dTLB-load-misses
 * ./kernel_miss ...` would attach counters unchanged on a host that has perf.
 *
 *   --kernel  saxpy | mul
 *   --n       element count (footprint = N * dtype bytes * #arrays)
 *   --pattern sequential | random   (random = shuffled index, one touch/element)
 *   --pages   4k | huge             (huge requests THP via madvise; granted TBD
 *                                    is reported from /proc/self/smaps_rollup)
 */
#define _GNU_SOURCE
#include "common.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static double measure_ghz(void) {
    uint64_t a = 1, n = 2000000000ull;
    double t0 = acs_now_sec();
#if defined(__x86_64__)
    __asm__ volatile(
        "1:\n\t add $1, %[a]\n\t sub $1, %[n]\n\t jnz 1b\n\t"
        : [a] "+r"(a), [n] "+r"(n) :: "cc");
#else
    volatile uint64_t s = 0; for (uint64_t i = 0; i < n; i++) a += 1; s = a; (void)s;
#endif
    double dt = acs_now_sec() - t0; acs_consume_i64((int64_t)a);
    return 2000000000.0 / dt / 1e9;
}
static long anon_hugepages_kib(void) {
    FILE *f = fopen("/proc/self/smaps_rollup", "r"); if (!f) return -1;
    char line[256]; long v = -1;
    while (fgets(line, sizeof line, f)) if (sscanf(line, "AnonHugePages: %ld kB", &v) == 1) break;
    fclose(f); return v;
}

int main(int argc, char **argv) {
    size_t n = 1 << 16;
    int reps = 8, warmup = 2, cpu = -1, want_header = 0, use_huge = 0, random_order = 0;
    double min_ms = 50.0;
    unsigned seed = 99u;
    const char *kernel = "saxpy", *experiment = "cache_miss";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define NEXT (argv[++i])
        if      (!strcmp(a, "--n"))       n = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--kernel"))  kernel = NEXT;
        else if (!strcmp(a, "--pattern")) random_order = !strcmp(NEXT, "random");
        else if (!strcmp(a, "--pages"))   use_huge = !strcmp(NEXT, "huge");
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

    /* 2 MiB-align the base when requesting huge pages so THP (`always`) can back
     * the mapping with 2 MiB pages at fault time; 4 KiB alignment otherwise. */
    size_t al = use_huge ? (2u*1024*1024) : 4096;
    acs_buf xb = acs_alloc(n * sizeof(double), al, 0);
    acs_buf yb = acs_alloc(n * sizeof(double), al, 0);
    double *x = xb.ptr, *y = yb.ptr;
    if (use_huge) { madvise(x, n*sizeof(double), MADV_HUGEPAGE); madvise(y, n*sizeof(double), MADV_HUGEPAGE); }
    unsigned s = seed;
    for (size_t i = 0; i < n; i++) { s = s*1664525u+1013904223u; x[i] = (double)((s>>8)&0xffff)/65536.0-0.5; y[i] = 0.25; }

    uint32_t *idx = NULL;
    if (random_order) {
        idx = malloc(n * sizeof(uint32_t));
        for (size_t i = 0; i < n; i++) idx[i] = (uint32_t)i;
        s = seed ^ 0x51edu;
        for (size_t i = n - 1; i > 0; i--) { s = s*1664525u+1013904223u; size_t j = s % (i+1); uint32_t t = idx[i]; idx[i]=idx[j]; idx[j]=t; }
    }

    double ghz = measure_ghz();
    long ahp = anon_hugepages_kib();
    const double aa = 0.5;

    /* warmup */
    for (int w = 0; w < warmup; w++) {
        if (random_order) for (size_t i=0;i<n;i++){ size_t j=idx[i]; y[j]=aa*x[j]+y[j]; }
        else              for (size_t i=0;i<n;i++) y[i]=aa*x[i]+y[i];
        acs_consume_f64(y[0]);
    }

    size_t iters = 1; double per;
    do {
        double t0 = acs_now_sec();
        for (size_t k=0;k<iters;k++) {
            if (random_order) for (size_t i=0;i<n;i++){ size_t j=idx[i]; y[j]=aa*x[j]+y[j]; }
            else              for (size_t i=0;i<n;i++) y[i]=aa*x[i]+y[i];
        }
        double dt = acs_now_sec()-t0; acs_consume_f64(y[0]); per = dt;
        if (per < min_ms/1000.0) iters *= 2;
    } while (per < min_ms/1000.0 && iters < (1u<<28));

    if (want_header)
        printf("experiment,kernel,pattern,pages,n,bytes,ghz,anon_thp_kib,rep,iters,time_s,ns_per_elem,gflops\n");

    double fpe = !strcmp(kernel,"mul") ? 1.0 : 2.0;
    for (int r = 0; r < reps; r++) {
        double t0 = acs_now_sec();
        for (size_t k=0;k<iters;k++) {
            if (random_order) for (size_t i=0;i<n;i++){ size_t j=idx[i]; y[j]=aa*x[j]+y[j]; }
            else              for (size_t i=0;i<n;i++) y[i]=aa*x[i]+y[i];
        }
        double dt = acs_now_sec()-t0; acs_consume_f64(y[0]);
        double per_call = dt/(double)iters;
        double nspe = per_call*1e9/(double)n;
        double gflops = fpe*(double)n/per_call/1e9;
        printf("%s,%s,%s,%s,%zu,%zu,%.3f,%ld,%d,%zu,%.9e,%.6e,%.6e\n",
               experiment, kernel, random_order?"random":"sequential", use_huge?"huge":"4k",
               n, n*sizeof(double)*2, ghz, ahp, r, iters, per_call, nspe, gflops);
    }
    acs_free(xb); acs_free(yb); free(idx);
    return 0;
}
