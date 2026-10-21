/*
 * mem_latency.c — zero-queue memory access latency (Project 2).
 *
 * Measures the latency of a single, dependent memory access to a working set of
 * a chosen size, so sweeping the size reveals the L1/L2/L3/DRAM latency steps.
 *
 * Method (lmbench-style pointer chase):
 *   - The working set is an array of indices laid out one node per `stride`
 *     bytes (default 64 B = one cache line). The nodes are linked into a single
 *     cycle so that `p = ring[p]` must complete before the next load can issue —
 *     one outstanding miss at a time, i.e. *zero-queue* latency.
 *   - A random (Sattolo) permutation defeats the hardware prefetcher; a
 *     sequential ring is offered too so the prefetcher's effect is visible.
 *   - Pages are pre-faulted and the ring is traversed before timing, so the
 *     working set is resident in the level under test and no page fault lands in
 *     the timed region.
 *
 * Knobs beyond size/pattern:
 *   --access B   access granularity: each node is a B-byte block (B >= 64, a
 *                multiple of 64) and every line of the block is loaded before the
 *                next pointer can be formed (the pointer is combined with the other
 *                lines through a runtime zero), so one "access" = one dependent
 *                B-byte request. B=64 is the classic one-line chase.
 *   --stride S   node spacing in bytes (>= access). The TLB experiment uses
 *                S = 4160 (= 4096 + 64): one node per 4 KiB page, staggered by one
 *                line so consecutive nodes fall into different L1/L2 sets.
 *   --pages 4k|huge  explicit page policy (MADV_NOHUGEPAGE / MADV_HUGEPAGE before
 *                first touch); the AnonHugePages actually granted is recorded.
 *   --gen lcg|xorshift  ring generator; --timer clock|tsc  timing source. The
 *                (xorshift, tsc) pair is the independent cross-check that
 *                substitutes for Intel MLC (not installed on the test host).
 *   --counters   user-space perf_event_open counters per access (cycles,
 *                instructions, L1D read misses, LLC read refs/misses, dTLB read
 *                misses = completed page walks).
 *
 * One invocation measures ONE configuration and prints raw CSV rows (one per
 * repetition) to stdout; scripts/run.sh sweeps the knobs.
 */
#define _GNU_SOURCE
#include "common.h"
#include "memprof.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { PAT_RANDOM, PAT_SEQ } pattern_t;

static const char *pattern_name(pattern_t p) {
    return p == PAT_RANDOM ? "random" : "sequential";
}

/* A runtime zero the compiler cannot constant-fold: used to make the next
 * pointer depend on every line of a multi-line access block. */
static volatile size_t g_zero = 0;

/* Build a pointer-chase ring of `nodes` nodes spaced `step` elements apart. */
static void build_ring(size_t *ring, size_t nodes, size_t step, pattern_t pat,
                       mp_gen_t gen, unsigned seed) {
    if (pat == PAT_SEQ) {
        for (size_t k = 0; k < nodes; k++)
            ring[k * step] = ((k + 1) % nodes) * step;
        return;
    }
    size_t *order = malloc(nodes * sizeof(size_t));
    if (!order) { fprintf(stderr, "mem_latency: oom order\n"); exit(1); }
    mp_sattolo(order, nodes, gen, seed);
    for (size_t k = 0; k < nodes; k++)
        ring[order[k] * step] = order[(k + 1) % nodes] * step;
    free(order);
}

/* The timed loop. extra = additional 64 B lines per access block (access/64-1). */
__attribute__((noinline))
static size_t chase(const size_t *ring, size_t p, size_t n, size_t extra, size_t zero) {
    if (extra == 0) {
        for (size_t k = 0; k < n; k++) p = ring[p];
        return p;
    }
    for (size_t k = 0; k < n; k++) {
        const size_t *b = ring + p;
        size_t x = 0;
        for (size_t l = 1; l <= extra; l++) x += b[l * 8];
        p = b[0] + (x & zero);
    }
    return p;
}

int main(int argc, char **argv) {
    size_t bytes = 256 * 1024;   /* working-set size */
    size_t stride = 0;           /* node spacing; 0 = same as access */
    size_t access = 64;          /* bytes per dependent access */
    pattern_t pat = PAT_RANDOM;
    mp_gen_t gen = MP_GEN_LCG;
    int use_tsc = 0, counters = 0;
    int reps = 10, warmup = 2, cpu = -1, want_header = 0, use_huge = 0;
    double min_ms = 50.0;
    unsigned seed = 2026u;
    const char *experiment = "latency";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc && strcmp(a, "--header") && strcmp(a, "--huge") && strcmp(a, "--counters")) {
            fprintf(stderr, "missing value for %s\n", a); return 2;
        }
#define NEXT (argv[++i])
        if      (!strcmp(a, "--bytes"))   bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--stride"))  stride = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--access"))  access = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--pattern")) pat = !strcmp(NEXT, "sequential") ? PAT_SEQ : PAT_RANDOM;
        else if (!strcmp(a, "--pages"))   use_huge = mp_parse_pages(NEXT);
        else if (!strcmp(a, "--huge"))    use_huge = 1;
        else if (!strcmp(a, "--gen"))     gen = !strcmp(NEXT, "xorshift") ? MP_GEN_XORSHIFT : MP_GEN_LCG;
        else if (!strcmp(a, "--timer"))   use_tsc = !strcmp(NEXT, "tsc");
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

    if (access < 64) access = 64;
    access = (access / 64) * 64;
    if (stride == 0) stride = access;
    if (stride < access) stride = access;
    if (stride % sizeof(size_t)) stride = (stride / sizeof(size_t) + 1) * sizeof(size_t);
    size_t extra = access / 64 - 1;

    if (cpu >= 0 && acs_pin_cpu(cpu) != 0)
        fprintf(stderr, "warning: could not pin to CPU %d\n", cpu);

    size_t step  = stride / sizeof(size_t);
    size_t elems = bytes / sizeof(size_t);
    size_t nodes = elems / step;
    if (nodes < 2) { fprintf(stderr, "mem_latency: working set too small\n"); return 2; }
    elems = nodes * step;                 /* trim to a whole number of nodes */
    bytes = elems * sizeof(size_t);

    mp_buf buf = mp_alloc(elems * sizeof(size_t) + 64 * (extra + 1), use_huge);
    size_t *ring = buf.ptr;

    /* pre-fault (first touch decides the page size) + place the ring */
    memset(ring, 0, elems * sizeof(size_t));
    build_ring(ring, nodes, step, pat, gen, seed);
    long ahp = mp_anon_thp_kib();

    double ghz = mp_measure_ghz();
    double tsc_ghz = use_tsc ? mp_tsc_ghz() : NAN;
    size_t zero = g_zero;

    /* warm the working set into the level under test */
    for (int w = 0; w < warmup; w++)
        acs_consume_i64((int64_t)chase(ring, 0, nodes, extra, zero));

    /* calibrate accesses so each timed rep >= min_ms */
    size_t accesses = nodes < 4096 ? 4096 : nodes;
    for (;;) {
        double t0 = acs_now_sec();
        acs_consume_i64((int64_t)chase(ring, 0, accesses, extra, zero));
        double dt = acs_now_sec() - t0;
        if (dt >= min_ms / 1000.0 || accesses >= ((size_t)1 << 34)) break;
        accesses *= 2;
    }

    mp_ctr ctr;
    mp_ctr_open(&ctr, counters);

    if (want_header) {
        printf("experiment,pattern,pages,gen,timer,bytes,stride,access,nodes,ghz,tsc_ghz,"
               "anon_thp_kib,rep,accesses,time_s,ns_per_access,cycles_per_access,gib_s");
        mp_ctr_header("pa");
        printf("\n");
    }

    size_t p = 0;
    for (int r = 0; r < reps; r++) {
        double cv[MP_NCTR], cover;
        mp_ctr_start(&ctr);
        double t0 = acs_now_sec();
        uint64_t c0 = use_tsc ? mp_rdtsc() : 0;
        p = chase(ring, p, accesses, extra, zero);
        uint64_t c1 = use_tsc ? mp_rdtsc() : 0;
        double dt = acs_now_sec() - t0;
        mp_ctr_stop(&ctr, cv, &cover);
        acs_consume_i64((int64_t)p);
        if (use_tsc) dt = (double)(c1 - c0) / (tsc_ghz * 1e9);
        double ns = dt * 1e9 / (double)accesses;
        printf("%s,%s,%s,%s,%s,%zu,%zu,%zu,%zu,%.3f,%.4f,%ld,%d,%zu,%.9e,%.6e,%.6e,%.6e",
               experiment, pattern_name(pat), use_huge ? "huge" : "4k", mp_gen_name(gen),
               use_tsc ? "tsc" : "clock", bytes, stride, access, nodes, ghz, tsc_ghz, ahp, r,
               accesses, dt, ns, ns * ghz, (double)access / ns * 1e9 / (1024.0 * 1024 * 1024));
        mp_ctr_print(cv, cover, (double)accesses);
        printf("\n");
    }

    mp_ctr_close(&ctr);
    mp_free(buf);
    return 0;
}
