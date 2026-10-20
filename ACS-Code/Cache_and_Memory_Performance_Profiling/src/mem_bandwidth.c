/*
 * mem_bandwidth.c — memory bandwidth and loaded throughput (Project 2).
 *
 * Streams one or more large arrays with a chosen kernel and reports delivered
 * bandwidth (GiB/s). Knobs:
 *   --kernel  read | write | copy | triad | rwmix
 *   --reads R rwmix only: R of every 10 element accesses are reads (R=10 -> 100%
 *             read, R=7 -> 70/30, R=5 -> 50/50, R=0 -> 100% write). Exact ratios.
 *   --pattern sequential | random  (random reads cache-line blocks in shuffled
 *             order to defeat the prefetcher; granularity set by --strideb)
 *   --strideb byte stride between touched elements (granularity sweep: 64/256/1024)
 *   --threads number of threads, each pinned to a distinct physical core, each
 *             streaming its own chunk. Sweeping this is the access-intensity
 *             (loaded-throughput) experiment for the knee / Little's Law.
 *   --bytes   total working-set bytes (split across threads)
 *
 * Read kernels use 8 independent accumulators so delivered bandwidth is limited
 * by the memory system, not the latency of a single reduction chain. Stores are
 * ordinary (write-allocate) stores; the report notes the implied read-for-
 * ownership traffic. One invocation = one configuration; raw CSV rows to stdout.
 */
#define _GNU_SOURCE
#include "common.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

typedef enum { K_READ, K_WRITE, K_COPY, K_TRIAD, K_RWMIX } kind_t;
typedef enum { PAT_SEQ, PAT_RANDOM } pattern_t;

static const char *kind_name(kind_t k) {
    switch (k) {
    case K_READ:  return "read";
    case K_WRITE: return "write";
    case K_COPY:  return "copy";
    case K_TRIAD: return "triad";
    default:      return "rwmix";
    }
}

typedef struct {
    int       id;
    int       cpu;          /* -1 = no pin */
    kind_t    kind;
    pattern_t pattern;
    size_t    n;            /* elements in this thread's chunk */
    size_t    step;         /* elements between touched items (strideb/8) */
    size_t    touched;      /* elements actually touched per pass */
    int       reads10;      /* rwmix reads per group of 10 */
    size_t    iters;
    double   *a, *b, *c;    /* this thread's buffers */
    size_t   *order;        /* random block order (pattern==RANDOM), length touched */
    double    sink;
} targ_t;

static pthread_barrier_t g_start, g_stop;

static void run_kernel(targ_t *t) {
    double *a = t->a, *b = t->b, *c = t->c;
    size_t step = t->step, touched = t->touched;
    double acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;
    double acc4 = 0, acc5 = 0, acc6 = 0, acc7 = 0;

    if (t->pattern == PAT_RANDOM) {
        /* one element per shuffled cache-line block; read-only (prefetch defeat) */
        const size_t *o = t->order;
        for (size_t it = 0; it < t->iters; it++)
            for (size_t k = 0; k < touched; k++) acc0 += a[o[k]];
        t->sink = acc0;
        return;
    }

    switch (t->kind) {
    case K_READ: {
        size_t i = 0, lim = (touched / 8) * 8 * step;
        for (size_t it = 0; it < t->iters; it++) {
            for (i = 0; i + 8 * step <= t->n; i += 8 * step) {
                acc0 += a[i];           acc1 += a[i + step];
                acc2 += a[i + 2*step];  acc3 += a[i + 3*step];
                acc4 += a[i + 4*step];  acc5 += a[i + 5*step];
                acc6 += a[i + 6*step];  acc7 += a[i + 7*step];
            }
            for (; i < t->n; i += step) acc0 += a[i];
        }
        (void)lim;
        t->sink = acc0+acc1+acc2+acc3+acc4+acc5+acc6+acc7;
        break; }
    case K_WRITE:
        for (size_t it = 0; it < t->iters; it++)
            for (size_t i = 0; i < t->n; i += step) a[i] = 1.0;
        t->sink = a[0];
        break;
    case K_COPY:
        for (size_t it = 0; it < t->iters; it++)
            for (size_t i = 0; i < t->n; i += step) b[i] = a[i];
        t->sink = b[0];
        break;
    case K_TRIAD:
        for (size_t it = 0; it < t->iters; it++)
            for (size_t i = 0; i < t->n; i += step) b[i] = a[i] + 3.0 * c[i];
        t->sink = b[0];
        break;
    case K_RWMIX: {
        /* groups of 10 touched elements: reads10 reads then (10-reads10) writes */
        int rd = t->reads10;
        for (size_t it = 0; it < t->iters; it++) {
            size_t i = 0;
            while (i + 10 * step <= t->n) {
                int j = 0;
                for (; j < rd; j++)  acc0 += a[i + (size_t)j * step];
                for (; j < 10; j++)  b[i + (size_t)j * step] = acc0;
                i += 10 * step;
            }
        }
        t->sink = acc0;
        break; }
    }
}

static void *worker(void *p) {
    targ_t *t = p;
    if (t->cpu >= 0) acs_pin_cpu(t->cpu);
    /* touch pages so faults stay out of the timed region */
    for (size_t i = 0; i < t->n; i++) { t->a[i] = 1.0; if (t->b) t->b[i] = 1.0; if (t->c) t->c[i] = 1.0; }
    pthread_barrier_wait(&g_start);
    run_kernel(t);
    pthread_barrier_wait(&g_stop);
    return NULL;
}

static size_t bytes_per_touch(kind_t k) {
    switch (k) {
    case K_COPY:  return 16; /* 1 read + 1 write */
    case K_TRIAD: return 24; /* 2 read + 1 write */
    default:      return 8;  /* read / write / rwmix: one 8 B access per touch */
    }
}

int main(int argc, char **argv) {
    size_t bytes = 512ull * 1024 * 1024;
    size_t strideb = 8;              /* contiguous doubles by default */
    kind_t kind = K_READ;
    pattern_t pattern = PAT_SEQ;
    int threads = 1, reps = 7, reads10 = 10, cpu0 = 0, want_header = 0, use_huge = 0;
    double min_ms = 100.0;
    unsigned seed = 7u;
    const char *experiment = "bandwidth";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define NEXT (argv[++i])
        if      (!strcmp(a, "--bytes"))   bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--strideb")) strideb = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--kernel")) { const char *v = NEXT;
            kind = !strcmp(v,"write") ? K_WRITE : !strcmp(v,"copy") ? K_COPY :
                   !strcmp(v,"triad") ? K_TRIAD : !strcmp(v,"rwmix") ? K_RWMIX : K_READ; }
        else if (!strcmp(a, "--pattern")) pattern = !strcmp(NEXT,"random") ? PAT_RANDOM : PAT_SEQ;
        else if (!strcmp(a, "--reads"))   reads10 = atoi(NEXT);
        else if (!strcmp(a, "--threads")) threads = atoi(NEXT);
        else if (!strcmp(a, "--reps"))    reps = atoi(NEXT);
        else if (!strcmp(a, "--min-ms"))  min_ms = atof(NEXT);
        else if (!strcmp(a, "--cpu0"))    cpu0 = atoi(NEXT);
        else if (!strcmp(a, "--seed"))    seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--huge"))    use_huge = 1;
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--header"))  want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (threads < 1) threads = 1;
    if (strideb < 8) strideb = 8;
    size_t step = strideb / 8;

    size_t per_elems = (bytes / 8) / (size_t)threads;
    per_elems = (per_elems / (10 * step)) * (10 * step);   /* whole rwmix groups */
    if (per_elems < 10 * step) per_elems = 10 * step;
    size_t touched = per_elems / step;

    int need_b = (kind == K_COPY || kind == K_TRIAD || kind == K_RWMIX);
    int need_c = (kind == K_TRIAD);

    targ_t *targ = calloc(threads, sizeof *targ);
    pthread_t *tid = calloc(threads, sizeof *tid);
    for (int i = 0; i < threads; i++) {
        targ[i].id = i;
        targ[i].cpu = cpu0 + i;          /* distinct physical cores 0..9 */
        targ[i].kind = kind;
        targ[i].pattern = pattern;
        targ[i].n = per_elems;
        targ[i].step = step;
        targ[i].touched = touched;
        targ[i].reads10 = reads10;
        acs_buf ab = acs_alloc(per_elems * sizeof(double), 4096, 0);
        targ[i].a = ab.ptr;
        if (use_huge) madvise(targ[i].a, per_elems * sizeof(double), MADV_HUGEPAGE);
        if (need_b) { acs_buf bb = acs_alloc(per_elems * sizeof(double), 4096, 0); targ[i].b = bb.ptr; }
        if (need_c) { acs_buf cb = acs_alloc(per_elems * sizeof(double), 4096, 0); targ[i].c = cb.ptr; }
        if (pattern == PAT_RANDOM) {
            targ[i].order = malloc(touched * sizeof(size_t));
            for (size_t k = 0; k < touched; k++) targ[i].order[k] = k * step;
            unsigned s = seed + (unsigned)i;
            for (size_t k = touched - 1; k > 0; k--) {
                s = s * 1664525u + 1013904223u; size_t j = s % (k + 1);
                size_t t = targ[i].order[k]; targ[i].order[k] = targ[i].order[j]; targ[i].order[j] = t;
            }
        }
    }

    /* calibrate iters on one thread's data so a timed rep >= min_ms */
    size_t iters = 1;
    {
        targ_t probe = targ[0]; probe.iters = 1; probe.cpu = -1;
        double per;
        do {
            probe.iters = iters;
            double t0 = acs_now_sec();
            run_kernel(&probe);
            double dt = acs_now_sec() - t0;
            acs_consume_f64(probe.sink);
            per = dt;
            if (per < min_ms / 1000.0) iters *= 2;
        } while (per < min_ms / 1000.0 && iters < (1u << 30));
    }

    size_t bpt = bytes_per_touch(kind);
    size_t touches_per_pass = (kind == K_RWMIX) ? (per_elems / step) : touched;
    double total_bytes = (double)touches_per_pass * (double)bpt * (double)iters * (double)threads;
    double total_elems = (double)touches_per_pass * (double)iters * (double)threads;

    int nbuf = 1 + (need_b ? 1 : 0) + (need_c ? 1 : 0);
    size_t wss_bytes = per_elems * (size_t)nbuf * sizeof(double); /* per-thread footprint */

    if (want_header)
        printf("experiment,kernel,pattern,pages,threads,strideb,reads10,wss_bytes,"
               "total_bytes,rep,iters,time_s,gib_s,ns_per_elem\n");

    for (int r = 0; r < reps; r++) {
        pthread_barrier_init(&g_start, NULL, threads + 1);
        pthread_barrier_init(&g_stop,  NULL, threads + 1);
        for (int i = 0; i < threads; i++) { targ[i].iters = iters; pthread_create(&tid[i], NULL, worker, &targ[i]); }
        pthread_barrier_wait(&g_start);
        double t0 = acs_now_sec();
        pthread_barrier_wait(&g_stop);
        double dt = acs_now_sec() - t0;
        for (int i = 0; i < threads; i++) { pthread_join(tid[i], NULL); acs_consume_f64(targ[i].sink); }
        pthread_barrier_destroy(&g_start);
        pthread_barrier_destroy(&g_stop);

        double gib = total_bytes / dt / (1024.0*1024.0*1024.0);
        double nspe = dt * 1e9 / total_elems;
        printf("%s,%s,%s,%s,%d,%zu,%d,%zu,%.0f,%d,%zu,%.9e,%.6e,%.6e\n",
               experiment, kind_name(kind), pattern == PAT_RANDOM ? "random" : "sequential",
               use_huge ? "huge" : "4k", threads, strideb, reads10, wss_bytes,
               total_bytes, r, iters, dt, gib, nspe);
    }
    return 0;
}
