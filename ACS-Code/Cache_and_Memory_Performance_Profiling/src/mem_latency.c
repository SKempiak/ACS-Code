/*
 * mem_latency.c — zero-queue memory access latency (Project 2).
 *
 * Measures the latency of a single, dependent memory access to a working set of
 * a chosen size, so sweeping the size reveals the L1/L2/L3/DRAM latency steps.
 *
 * Method (lmbench-style pointer chase):
 *   - The working set is an array of indices laid out one node per `stride`
 *     bytes (default 64 B = one cache line). The nodes are linked into a single
 *     cycle so that `i = ring[i]` must complete before the next load can issue —
 *     one outstanding miss at a time, i.e. *zero-queue* latency.
 *   - A random (Sattolo) permutation defeats the hardware prefetcher; a
 *     sequential ring is offered too so the prefetcher's effect is visible.
 *   - Pages are pre-faulted and the ring is traversed once before timing, so the
 *     working set is resident in the level under test (for sets that fit) and no
 *     page fault lands in the timed region.
 *   - The chase loop is `p = ring[p]` — one dependent load plus a trivial move;
 *     we report time / accesses as ns per access and convert to cycles using an
 *     effective CPU frequency measured at startup (dependent add chain).
 *
 * One invocation measures ONE configuration and prints raw CSV rows (one per
 * repetition) to stdout; scripts/run.sh sweeps the knobs. Reuses common.c for
 * timing, aligned allocation and pinning.
 *
 * NOTE: perf is not available on the test host (perf_event_paranoid=2, perf not
 * installed), so the cache level each size lands in is attributed from the known
 * cache geometry and the measured latency curve, not from counters.
 */
#define _GNU_SOURCE
#include "common.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/* ---------------------------------------------------------- frequency probe */
/* Effective GHz under load, from a strictly dependent add chain (one add per
 * cycle on this core). Used only to convert ns -> cycles for the report; the
 * governor is `powersave` with turbo on, so this is the realised frequency of
 * the measurement, which is exactly what we want for the conversion. */
static double measure_ghz(void) {
    uint64_t a = 1, n = 2000000000ull;
    double t0 = acs_now_sec();
#if defined(__x86_64__)
    /* one dependent ADD per iteration; ADD latency is 1 cycle and the SUB/JNZ
     * loop control macro-fuses, so iterations/second == the realised core GHz. */
    __asm__ volatile(
        "1:\n\t add $1, %[a]\n\t sub $1, %[n]\n\t jnz 1b\n\t"
        : [a] "+r"(a), [n] "+r"(n) :: "cc");
#else
    volatile uint64_t s = 0;
    for (uint64_t i = 0; i < n; i++) a += 1; /* fallback: approximate */
    s = a; (void)s;
#endif
    double dt = acs_now_sec() - t0;
    acs_consume_i64((int64_t)a);
    return 2000000000.0 / dt / 1e9;
}

/* ---------------------------------------------------------- ring layout */
typedef enum { PAT_RANDOM, PAT_SEQ } pattern_t;

static const char *pattern_name(pattern_t p) {
    return p == PAT_RANDOM ? "random" : "sequential";
}

/* Build a pointer-chase ring of `nodes` nodes spaced `step` elements apart in
 * `ring`. Random uses Sattolo's algorithm (guarantees a single full cycle). */
static void build_ring(size_t *ring, size_t nodes, size_t step, pattern_t pat,
                       unsigned seed) {
    /* node k lives at element index k*step */
    if (pat == PAT_SEQ) {
        for (size_t k = 0; k < nodes; k++)
            ring[k * step] = ((k + 1) % nodes) * step;
        return;
    }
    /* order[] is a permutation of node indices 0..nodes-1 */
    size_t *order = malloc(nodes * sizeof(size_t));
    if (!order) { fprintf(stderr, "mem_latency: oom order\n"); exit(1); }
    for (size_t k = 0; k < nodes; k++) order[k] = k;
    unsigned s = seed;
    for (size_t i = nodes - 1; i > 0; i--) { /* Sattolo: j in [0, i) */
        s = s * 1664525u + 1013904223u;
        size_t j = s % i;
        size_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (size_t k = 0; k < nodes; k++)
        ring[order[k] * step] = order[(k + 1) % nodes] * step;
    free(order);
}

/* AnonHugePages (KiB) backing this process, read from /proc/self/smaps_rollup
 * (0 if unavailable). Lets the report state whether huge pages were actually
 * granted rather than merely requested. */
static long anon_hugepages_kib(void) {
    FILE *f = fopen("/proc/self/smaps_rollup", "r");
    if (!f) return -1;
    char line[256];
    long v = -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "AnonHugePages: %ld kB", &v) == 1) break;
    fclose(f);
    return v;
}

int main(int argc, char **argv) {
    size_t bytes = 256 * 1024;   /* working-set size */
    size_t stride = 64;          /* one node per cache line by default */
    pattern_t pat = PAT_RANDOM;
    int reps = 10, warmup = 2, cpu = -1, want_header = 0, use_huge = 0;
    double min_ms = 50.0;
    unsigned seed = 2026u;
    const char *experiment = "latency";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define NEXT (argv[++i])
        if      (!strcmp(a, "--bytes"))   bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--stride"))  stride = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--pattern")) pat = !strcmp(NEXT, "sequential") ? PAT_SEQ : PAT_RANDOM;
        else if (!strcmp(a, "--reps"))    reps = atoi(NEXT);
        else if (!strcmp(a, "--min-ms"))  min_ms = atof(NEXT);
        else if (!strcmp(a, "--warmup"))  warmup = atoi(NEXT);
        else if (!strcmp(a, "--cpu"))     cpu = atoi(NEXT);
        else if (!strcmp(a, "--seed"))    seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--huge"))    use_huge = 1;
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--header"))  want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }

    if (stride < sizeof(size_t)) stride = sizeof(size_t);
    if (cpu >= 0 && acs_pin_cpu(cpu) != 0)
        fprintf(stderr, "warning: could not pin to CPU %d\n", cpu);

    size_t step   = stride / sizeof(size_t);
    size_t elems  = bytes / sizeof(size_t);
    size_t nodes  = elems / step;
    if (nodes < 2) { fprintf(stderr, "mem_latency: working set too small\n"); return 2; }
    elems = nodes * step;                 /* trim to a whole number of nodes */
    bytes = elems * sizeof(size_t);

    acs_buf buf = acs_alloc(elems * sizeof(size_t), 4096, 0);
    size_t *ring = buf.ptr;
    if (use_huge) madvise(ring, elems * sizeof(size_t), MADV_HUGEPAGE);

    /* pre-fault + place the ring */
    memset(ring, 0, elems * sizeof(size_t));
    build_ring(ring, nodes, step, pat, seed);

    double ghz = measure_ghz();
    long ahp = anon_hugepages_kib();

    /* warm the working set into the level under test */
    for (int w = 0; w < warmup; w++) {
        size_t p = 0;
        for (size_t k = 0; k < nodes; k++) p = ring[p];
        acs_consume_i64((int64_t)p);
    }

    /* calibrate accesses so each timed rep >= min_ms */
    size_t accesses = nodes;
    {
        double per;
        do {
            size_t p = 0;
            double t0 = acs_now_sec();
            for (size_t k = 0; k < accesses; k++) p = ring[p];
            double dt = acs_now_sec() - t0;
            acs_consume_i64((int64_t)p);
            per = dt;
            if (per < min_ms / 1000.0) accesses *= 2;
        } while (per < min_ms / 1000.0 && accesses < ((size_t)1 << 32));
    }

    if (want_header)
        printf("experiment,pattern,pages,bytes,stride,nodes,ghz,anon_thp_kib,"
               "rep,accesses,time_s,ns_per_access,cycles_per_access\n");

    for (int r = 0; r < reps; r++) {
        size_t p = 0;
        double t0 = acs_now_sec();
        for (size_t k = 0; k < accesses; k++) p = ring[p];
        double dt = acs_now_sec() - t0;
        acs_consume_i64((int64_t)p);
        double ns = dt * 1e9 / (double)accesses;
        printf("%s,%s,%s,%zu,%zu,%zu,%.3f,%ld,%d,%zu,%.9e,%.6e,%.6e\n",
               experiment, pattern_name(pat), use_huge ? "huge" : "4k",
               bytes, stride, nodes, ghz, ahp, r, accesses, dt, ns, ns * ghz);
    }

    acs_free(buf);
    return 0;
}
