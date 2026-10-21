/*
 * mem_bandwidth.c — memory bandwidth (Project 2).
 *
 * Streams one or more large arrays with a chosen kernel and reports delivered
 * bandwidth (GiB/s). Knobs:
 *   --kernel  read | write | copy | triad | rwmix
 *   --reads R rwmix only: of every 10 consecutive 64 B *lines*, the first R are
 *             read and the remaining 10-R are fully overwritten (R=10 -> 100% read,
 *             7 -> 70/30, 5 -> 50/50, 0 -> 100% write). Mixing at line granularity
 *             makes the ratio hold for the lines the memory system moves, not only
 *             for the bytes the program touches (an element-level mix would touch
 *             every line in both directions).
 *   --access B  access-size granularity (B = 64, 256, 1024, ...): the buffer is
 *             split into B-byte blocks and every byte of a block is read (vector
 *             loads) before moving to the next block. --pattern sequential visits
 *             blocks in address order, --pattern random in a shuffled order. All
 *             bytes moved are useful bytes.
 *   --strideb S  (secondary, used when --access is 0) byte stride between touched
 *             8 B elements; only one 8 B element per stride is used.
 *   --threads number of threads, thread i pinned to CPU cpu0+i, each streaming
 *             its own chunk.
 *   --bytes   total working-set bytes (split across threads)
 *   --pages   4k | huge (explicit page policy; granted AnonHugePages recorded)
 *
 * The strided read kernel uses 8 independent accumulators so delivered bandwidth
 * is not limited by one FP-add chain. Stores are ordinary (write-allocate) stores,
 * so each written line also costs a read-for-ownership. One invocation = one
 * configuration; raw CSV rows to stdout.
 */
#define _GNU_SOURCE
#include "common.h"
#include "memprof.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    size_t    n;            /* elements (doubles) in this thread's chunk */
    size_t    step;         /* elements between touched items (strideb/8) */
    size_t    touched;      /* items touched per pass */
    size_t    access;       /* block bytes (access mode) or 0 */
    int       reads10;      /* rwmix: lines read per group of 10 */
    size_t    iters;
    double   *a, *b, *c;    /* this thread's buffers */
    size_t   *order;        /* random order (elements or block offsets) */
    double    sink;
} targ_t;

static pthread_barrier_t g_start, g_stop;

/* Read one B-byte block with independent 64-bit integer accumulators (the
 * compiler vectorizes this into 256-bit loads; no FP reassociation needed). */
static inline uint64_t read_block(const uint64_t *p, size_t words) {
    uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
    for (size_t i = 0; i < words; i += 8) {
        s0 += p[i];     s1 += p[i + 1]; s2 += p[i + 2]; s3 += p[i + 3];
        s4 += p[i + 4]; s5 += p[i + 5]; s6 += p[i + 6]; s7 += p[i + 7];
    }
    return s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7;
}

static void run_kernel(targ_t *t) {
    double *a = t->a, *b = t->b, *c = t->c;
    size_t step = t->step, touched = t->touched;
    double acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;
    double acc4 = 0, acc5 = 0, acc6 = 0, acc7 = 0;

    if (t->access) {
        /* access-size granularity: full B-byte blocks, in order or shuffled */
        const uint64_t *base = (const uint64_t *)a;
        size_t words = t->access / 8, nblk = touched;
        uint64_t s = 0;
        for (size_t it = 0; it < t->iters; it++) {
            if (t->pattern == PAT_RANDOM)
                for (size_t k = 0; k < nblk; k++) s += read_block(base + t->order[k], words);
            else
                for (size_t k = 0; k < nblk; k++) s += read_block(base + k * words, words);
        }
        t->sink = (double)s;
        return;
    }

    if (t->pattern == PAT_RANDOM) {
        /* one 8 B element per shuffled stride-sized block (prefetch defeat) */
        const size_t *o = t->order;
        for (size_t it = 0; it < t->iters; it++)
            for (size_t k = 0; k < touched; k++) acc0 += a[o[k]];
        t->sink = acc0;
        return;
    }

    switch (t->kind) {
    case K_READ: {
        for (size_t it = 0; it < t->iters; it++) {
            size_t i = 0;
            for (; i + 8 * step <= t->n; i += 8 * step) {
                acc0 += a[i];           acc1 += a[i + step];
                acc2 += a[i + 2*step];  acc3 += a[i + 3*step];
                acc4 += a[i + 4*step];  acc5 += a[i + 5*step];
                acc6 += a[i + 6*step];  acc7 += a[i + 7*step];
            }
            for (; i < t->n; i += step) acc0 += a[i];
        }
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
        /* groups of 10 lines (80 doubles): reads10 lines read, the rest written */
        const size_t L = 8, G = 10 * L;
        size_t rd = (size_t)t->reads10 * L;
        uint64_t s = 0;
        for (size_t it = 0; it < t->iters; it++) {
            for (size_t i = 0; i + G <= t->n; i += G) {
                if (rd) s += read_block((const uint64_t *)(a + i), rd);
                for (size_t j = rd; j < G; j++) a[i + j] = 1.0;
            }
        }
        t->sink = (double)s;
        break; }
    }
}

static void *worker(void *p) {
    targ_t *t = p;
    if (t->cpu >= 0) acs_pin_cpu(t->cpu);
    pthread_barrier_wait(&g_start);
    run_kernel(t);
    pthread_barrier_wait(&g_stop);
    return NULL;
}

static size_t bytes_per_touch(kind_t k) {
    switch (k) {
    case K_COPY:  return 16; /* 1 read + 1 write */
    case K_TRIAD: return 24; /* 2 read + 1 write */
    default:      return 8;  /* read / write: one 8 B access per touch */
    }
}

static void shuffle(size_t *v, size_t n, unsigned seed) {
    unsigned s = seed;
    for (size_t k = n - 1; k > 0; k--) {
        s = s * 1664525u + 1013904223u;
        size_t j = s % (k + 1);
        size_t t = v[k]; v[k] = v[j]; v[j] = t;
    }
}

int main(int argc, char **argv) {
    size_t bytes = 512ull * 1024 * 1024;
    size_t strideb = 8;              /* contiguous doubles by default */
    size_t access = 0;               /* 0 = strided-element mode */
    kind_t kind = K_READ;
    pattern_t pattern = PAT_SEQ;
    int threads = 1, reps = 7, reads10 = 10, cpu0 = 0, want_header = 0, use_huge = 0;
    double min_ms = 100.0;
    unsigned seed = 7u;
    const char *experiment = "bandwidth";

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc && strcmp(a, "--header") && strcmp(a, "--huge")) {
            fprintf(stderr, "missing value for %s\n", a); return 2;
        }
#define NEXT (argv[++i])
        if      (!strcmp(a, "--bytes"))   bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--strideb")) strideb = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--access"))  access = strtoull(NEXT, 0, 0);
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
        else if (!strcmp(a, "--pages"))   use_huge = mp_parse_pages(NEXT);
        else if (!strcmp(a, "--huge"))    use_huge = 1;
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--header"))  want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (threads < 1) threads = 1;
    if (strideb < 8) strideb = 8;
    if (reads10 < 0) reads10 = 0;
    if (reads10 > 10) reads10 = 10;
    if (access) {
        if (access < 64) access = 64;
        access = (access / 64) * 64;
        kind = K_READ;
    }
    size_t step = strideb / 8;

    /* elements per thread, rounded to whole units of the access pattern */
    size_t unit = access ? access / 8 : (kind == K_RWMIX ? 80 : 10 * step);
    size_t per_elems = (bytes / 8) / (size_t)threads;
    per_elems = (per_elems / unit) * unit;
    if (per_elems < unit) per_elems = unit;
    size_t touched = access ? per_elems / unit : per_elems / step;

    int need_b = (kind == K_COPY || kind == K_TRIAD);
    int need_c = (kind == K_TRIAD);

    targ_t *targ = calloc(threads, sizeof *targ);
    pthread_t *tid = calloc(threads, sizeof *tid);
    mp_buf *bufs = calloc((size_t)threads * 3, sizeof *bufs);
    mp_buf *obufs = calloc((size_t)threads, sizeof *obufs);
    for (int i = 0; i < threads; i++) {
        targ_t *t = &targ[i];
        t->id = i;
        t->cpu = cpu0 + i;          /* distinct physical cores cpu0.. */
        t->kind = kind;
        t->pattern = pattern;
        t->n = per_elems;
        t->step = step;
        t->touched = touched;
        t->access = access;
        t->reads10 = reads10;
        bufs[3*i] = mp_alloc(per_elems * sizeof(double), use_huge);
        t->a = bufs[3*i].ptr;
        if (need_b) { bufs[3*i+1] = mp_alloc(per_elems * sizeof(double), use_huge); t->b = bufs[3*i+1].ptr; }
        if (need_c) { bufs[3*i+2] = mp_alloc(per_elems * sizeof(double), use_huge); t->c = bufs[3*i+2].ptr; }
        /* first touch (pages faulted once, outside every timed region) */
        for (size_t k = 0; k < per_elems; k++) {
            t->a[k] = 1.0; if (t->b) t->b[k] = 1.0; if (t->c) t->c[k] = 1.0;
        }
        if (pattern == PAT_RANDOM) {
            /* same page policy as the data, so AnonHugePages reflects the policy */
            obufs[i] = mp_alloc(touched * sizeof(size_t), use_huge);
            t->order = obufs[i].ptr;
            for (size_t k = 0; k < touched; k++) t->order[k] = k * (access ? unit : step);
            shuffle(t->order, touched, seed + (unsigned)i);
        }
    }
    long ahp = mp_anon_thp_kib();

    /* calibrate iters on one thread's data so a timed rep >= min_ms */
    size_t iters = 1;
    {
        targ_t probe = targ[0]; probe.cpu = -1;
        for (;;) {
            probe.iters = iters;
            double t0 = acs_now_sec();
            run_kernel(&probe);
            double dt = acs_now_sec() - t0;
            acs_consume_f64(probe.sink);
            if (dt >= min_ms / 1000.0 || iters >= (1u << 30)) break;
            iters *= 2;
        }
    }

    double bytes_per_pass;
    if (access)               bytes_per_pass = (double)touched * (double)access;
    else if (kind == K_RWMIX) bytes_per_pass = (double)per_elems * 8.0;   /* every line read or written once */
    else                      bytes_per_pass = (double)touched * (double)bytes_per_touch(kind);
    double elems_per_pass = access ? (double)touched : (kind == K_RWMIX ? (double)per_elems / 8.0 : (double)touched);
    double total_bytes = bytes_per_pass * (double)iters * (double)threads;
    double total_elems = elems_per_pass * (double)iters * (double)threads;

    int nbuf = 1 + (need_b ? 1 : 0) + (need_c ? 1 : 0);
    size_t wss_bytes = per_elems * (size_t)nbuf * sizeof(double); /* per-thread footprint */

    if (want_header)
        printf("experiment,kernel,pattern,pages,threads,strideb,access,reads10,wss_bytes,"
               "anon_thp_kib,total_bytes,rep,iters,time_s,gib_s,ns_per_elem\n");

    /* r = -1 is an untimed warm-up repetition with all threads (not printed) */
    for (int r = -1; r < reps; r++) {
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

        if (r < 0) continue;
        double gib = total_bytes / dt / (1024.0*1024.0*1024.0);
        double nspe = dt * 1e9 / total_elems;
        printf("%s,%s,%s,%s,%d,%zu,%zu,%d,%zu,%ld,%.0f,%d,%zu,%.9e,%.6e,%.6e\n",
               experiment, kind_name(kind), pattern == PAT_RANDOM ? "random" : "sequential",
               use_huge ? "huge" : "4k", threads, access ? access : strideb, access, reads10,
               wss_bytes, ahp, total_bytes, r, iters, dt, gib, nspe);
    }
    for (int i = 0; i < threads * 3; i++) mp_free(bufs[i]);
    for (int i = 0; i < threads; i++) mp_free(obufs[i]);
    return 0;
}
