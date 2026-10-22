/*
 * mem_loaded.c — loaded latency and throughput under controlled intensity (P2).
 *
 * Intel MLC's "loaded latency" idea, built from scratch because MLC is not
 * available on the test host: T load-generator threads drive memory traffic while
 * a latency probe measures dependent-access latency *at the same time*. Every
 * point therefore yields both axes of the throughput–latency curve.
 *
 *   Generators (thread i pinned to the i-th CPU of --cpus, each on its own
 *   DRAM-resident buffer of --bytes, default 128 MiB):
 *     --kernel stream   sequential read, two 256-bit loads per 64 B line
 *                       (--delay D inserts D empty loop iterations per line to
 *                       throttle the offered load, like MLC's injection delay)
 *     --kernel rwmix    groups of 10 lines: --reads R lines read, 10-R written
 *                       (full-line stores; each costs an RFO + write-back)
 *     --kernel chase    --chains k independent random pointer chases per thread:
 *                       at most k misses outstanding per thread, so the offered
 *                       concurrency N = T*k is *known*; lambda * (probe latency)
 *                       then shows how many of them actually reach memory.
 *   Probe (main thread, pinned to --probe-cpu; -1 disables): one random pointer
 *   chase (one line per node, Sattolo ring, --probe-bytes, default 256 MiB),
 *   i.e. the zero-queue method of mem_latency, run while the generators load the
 *   memory system. T=0 with the probe gives the unloaded latency of the same
 *   setup.
 *
 * Measurement: generators run continuously and publish progress counters
 * (lines or chase steps) with relaxed atomic stores every few KiB. For each
 * repetition the main thread snapshots all counters, runs the probe (or sleeps)
 * for a window of --min-ms, and snapshots again; throughput = progress / window,
 * so throughput and latency come from the same interval.
 *
 * Output (one row per repetition):
 *   gen_gib_s      demand bytes moved by the generators (64 B per line/step)
 *   total_gib_s    gen_gib_s + the probe's lines
 *   traffic_gib_s  estimated DRAM traffic: rwmix writes counted twice (RFO +
 *                  write-back); equals total_gib_s for read-only kernels
 *   gen_lat_ns     chase only: mean per-chain time per dependent step (= W)
 *   probe_ns       probe latency per access under load (nan without probe)
 *   imc_rd_gib_s / imc_wr_gib_s  DRAM bytes read / written per second, measured by the
 *                  system-wide uncore IMC counters over the same window (nan without them;
 *                  includes all other system traffic).
 *   little_l       lambda * W. For chase, lambda = generator lines/s and W =
 *                  gen_lat_ns, so little_l == T*k by construction: it only checks
 *                  the progress accounting (derive.py computes the informative
 *                  lambda * probe_ns instead). Otherwise lambda = all lines/s
 *                  (generators + probe) and W = probe_ns, the measured *loaded*
 *                  latency, giving the average number of lines in flight.
 */
#define _GNU_SOURCE
#include "common.h"
#include "memprof.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__AVX2__)
#include <immintrin.h>
#endif

#define MAXT  64
#define MAXCH 64

typedef enum { G_STREAM, G_RWMIX, G_CHASE } gkind_t;

static const char *gkind_name(gkind_t k) {
    return k == G_STREAM ? "stream" : k == G_RWMIX ? "rwmix" : "chase";
}

typedef struct {
    _Alignas(64) _Atomic uint64_t progress;   /* lines (stream/rwmix) or chase steps */
    char pad[64 - sizeof(uint64_t)];
} prog_t;

typedef struct {
    int       id, cpu, huge, reads10, chains, delay;
    gkind_t   kind;
    size_t    bytes;
    uint64_t  seed;
    mp_buf    buf;
    void     *start[MAXCH];
    uint64_t  sink;
} gen_t;

static prog_t            g_prog[MAXT];
static _Atomic int       g_go, g_stop;
static pthread_barrier_t g_ready;

#define STOPPED() atomic_load_explicit(&g_stop, memory_order_relaxed)
#define PUBLISH(id, v) atomic_store_explicit(&g_prog[id].progress, (v), memory_order_relaxed)

/* Link `nodes` 64 B nodes of `base` into one random cycle (pointer per node). */
static void build_pointer_ring(char *base, size_t nodes, mp_gen_t gen, uint64_t seed,
                               void **starts, int nstarts) {
    size_t *order = malloc(nodes * sizeof(size_t));
    if (!order) { fprintf(stderr, "mem_loaded: oom\n"); exit(1); }
    mp_sattolo(order, nodes, gen, seed);
    for (size_t k = 0; k < nodes; k++)
        *(void **)(base + order[k] * 64) = base + order[(k + 1) % nodes] * 64;
    for (int j = 0; j < nstarts; j++)
        starts[j] = base + order[(size_t)j * nodes / (size_t)nstarts] * 64;
    free(order);
}

static inline void spin(int d) {
    for (int k = 0; k < d; k++) __asm__ volatile("");
}

static void gen_stream(gen_t *g) {
    const char *b = g->buf.ptr;
    size_t nl = g->bytes / 64, CH = 1024;
    uint64_t done = 0;
    int d = g->delay;
#if defined(__AVX2__)
    __m256i a0 = _mm256_setzero_si256(), a1 = _mm256_setzero_si256();
#else
    uint64_t a0 = 0, a1 = 0;
#endif
    while (!STOPPED()) {
        for (size_t i = 0; i < nl; i += CH) {
            size_t e = i + CH < nl ? i + CH : nl;
            for (size_t j = i; j < e; j++) {
#if defined(__AVX2__)
                const __m256i *q = (const __m256i *)(b + j * 64);
                a0 = _mm256_add_epi64(a0, _mm256_load_si256(q));
                a1 = _mm256_add_epi64(a1, _mm256_load_si256(q + 1));
#else
                const uint64_t *q = (const uint64_t *)(b + j * 64);
                a0 += q[0] + q[2] + q[4] + q[6];
                a1 += q[1] + q[3] + q[5] + q[7];
#endif
                if (d) spin(d);
            }
            done += e - i;
            PUBLISH(g->id, done);
            if (STOPPED()) break;
        }
    }
#if defined(__AVX2__)
    uint64_t t[4];
    _mm256_storeu_si256((__m256i *)t, _mm256_add_epi64(a0, a1));
    g->sink = t[0] + t[1] + t[2] + t[3];
#else
    g->sink = a0 + a1;
#endif
}

static void gen_rwmix(gen_t *g) {
    char *b = g->buf.ptr;
    size_t groups = g->bytes / 640;
    int rd = g->reads10, d = g->delay;
    uint64_t done = 0;
#if defined(__AVX2__)
    __m256i acc = _mm256_setzero_si256(), one = _mm256_set1_epi64x(1);
#else
    uint64_t acc = 0;
#endif
    while (!STOPPED()) {
        for (size_t gi = 0; gi < groups; gi++) {
            char *gp = b + gi * 640;
            for (int l = 0; l < 10; l++) {
#if defined(__AVX2__)
                __m256i *q = (__m256i *)(gp + l * 64);
                if (l < rd) {
                    acc = _mm256_add_epi64(acc, _mm256_load_si256(q));
                    acc = _mm256_add_epi64(acc, _mm256_load_si256(q + 1));
                } else {
                    _mm256_store_si256(q, one);
                    _mm256_store_si256(q + 1, one);
                }
#else
                uint64_t *q = (uint64_t *)(gp + l * 64);
                if (l < rd) for (int w = 0; w < 8; w++) acc += q[w];
                else        for (int w = 0; w < 8; w++) q[w] = 1;
#endif
                if (d) spin(d);
            }
            done += 10;
            if ((gi & 15) == 15) {
                PUBLISH(g->id, done);
                if (STOPPED()) break;
            }
        }
    }
#if defined(__AVX2__)
    uint64_t t[4];
    _mm256_storeu_si256((__m256i *)t, acc);
    g->sink = t[0] + t[1] + t[2] + t[3];
#else
    g->sink = acc;
#endif
}

static void gen_chase(gen_t *g) {
    void *p[MAXCH];
    int k = g->chains;
    for (int j = 0; j < k; j++) p[j] = g->start[j];
    uint64_t done = 0;
    while (!STOPPED()) {
        for (int r = 0; r < 64; r++)
            for (int j = 0; j < k; j++) p[j] = *(void **)p[j];
        done += 64u * (uint64_t)k;
        PUBLISH(g->id, done);
    }
    uintptr_t s = 0;
    for (int j = 0; j < k; j++) s += (uintptr_t)p[j];
    g->sink = s;
}

static void *gen_thread(void *arg) {
    gen_t *g = arg;
    if (g->cpu >= 0 && acs_pin_cpu(g->cpu) != 0)
        fprintf(stderr, "warning: could not pin generator to CPU %d\n", g->cpu);
    /* allocate and first-touch on the generator's own core */
    g->buf = mp_alloc(g->bytes, g->huge);
    memset(g->buf.ptr, 1, g->bytes);
    if (g->kind == G_CHASE)
        build_pointer_ring(g->buf.ptr, g->bytes / 64, MP_GEN_XORSHIFT, g->seed, g->start, g->chains);
    pthread_barrier_wait(&g_ready);
    while (!atomic_load_explicit(&g_go, memory_order_acquire)) __asm__ volatile("pause");
    switch (g->kind) {
    case G_STREAM: gen_stream(g); break;
    case G_RWMIX:  gen_rwmix(g);  break;
    case G_CHASE:  gen_chase(g);  break;
    }
    return NULL;
}

/* Probe: chase until `window` seconds elapse; returns accesses done. */
static size_t probe_window(void **pp, double window, double *dt_out) {
    void *p = *pp;
    size_t n = 0;
    double t0 = acs_now_sec(), dt;
    do {
        for (int k = 0; k < 2048; k++) p = *(void **)p;
        n += 2048;
        dt = acs_now_sec() - t0;
    } while (dt < window);
    *pp = p;
    *dt_out = dt;
    return n;
}

static void sleep_window(double window, double *dt_out) {
    double t0 = acs_now_sec(), dt;
    struct timespec ts = {0, 1000000};   /* 1 ms */
    do { nanosleep(&ts, NULL); dt = acs_now_sec() - t0; } while (dt < window);
    *dt_out = dt;
}

static int parse_cpus(const char *s, int *out, int max) {
    int n = 0;
    char *dup = strdup(s), *save = NULL;
    for (char *t = strtok_r(dup, ",", &save); t && n < max; t = strtok_r(NULL, ",", &save))
        out[n++] = atoi(t);
    free(dup);
    return n;
}

int main(int argc, char **argv) {
    int threads = 1, probe_cpu = 2, reads10 = 10, chains = 1, delay = 0;
    int reps = 8, use_huge = 0, want_header = 0;
    size_t bytes = 128ull << 20, probe_bytes = 256ull << 20;
    double min_ms = 200.0, warm_ms = 100.0;
    unsigned seed = 2026u;
    gkind_t kind = G_STREAM;
    const char *experiment = "loaded", *cpus_arg = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc && strcmp(a, "--header")) { fprintf(stderr, "missing value for %s\n", a); return 2; }
#define NEXT (argv[++i])
        if      (!strcmp(a, "--threads"))   threads = atoi(NEXT);
        else if (!strcmp(a, "--cpus"))      cpus_arg = NEXT;
        else if (!strcmp(a, "--probe-cpu")) probe_cpu = atoi(NEXT);
        else if (!strcmp(a, "--kernel"))  { const char *v = NEXT;
            kind = !strcmp(v, "rwmix") ? G_RWMIX : !strcmp(v, "chase") ? G_CHASE : G_STREAM; }
        else if (!strcmp(a, "--reads"))     reads10 = atoi(NEXT);
        else if (!strcmp(a, "--chains"))    chains = atoi(NEXT);
        else if (!strcmp(a, "--delay"))     delay = atoi(NEXT);
        else if (!strcmp(a, "--bytes"))     bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--probe-bytes")) probe_bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--pages"))     use_huge = mp_parse_pages(NEXT);
        else if (!strcmp(a, "--reps"))      reps = atoi(NEXT);
        else if (!strcmp(a, "--min-ms"))    min_ms = atof(NEXT);
        else if (!strcmp(a, "--warm-ms"))   warm_ms = atof(NEXT);
        else if (!strcmp(a, "--seed"))      seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--header"))    want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (threads < 0) threads = 0;
    if (threads > MAXT) threads = MAXT;
    if (chains < 1) chains = 1;
    if (chains > MAXCH) chains = MAXCH;
    if (reads10 < 0) reads10 = 0;
    if (reads10 > 10) reads10 = 10;
    if (delay < 0) delay = 0;
    bytes = (bytes / 640) * 640;
    if (bytes < 640 * 64) bytes = 640 * 64;
    int probe = probe_cpu >= 0;
    if (!probe && threads == 0) { fprintf(stderr, "mem_loaded: nothing to measure\n"); return 2; }

    /* generator CPUs: --cpus list, else 0,1,2,... skipping the probe CPU */
    int cpus[MAXT];
    int ncpus = cpus_arg ? parse_cpus(cpus_arg, cpus, MAXT) : 0;
    if (!cpus_arg)
        for (int c = 0; ncpus < threads; c++) if (c != probe_cpu) cpus[ncpus++] = c;
    if (ncpus < threads) { fprintf(stderr, "mem_loaded: --cpus lists %d CPUs < %d threads\n", ncpus, threads); return 2; }
    for (int i = 0; i < threads; i++)
        if (probe && cpus[i] == probe_cpu) { fprintf(stderr, "mem_loaded: generator on probe CPU\n"); return 2; }

    if (probe && acs_pin_cpu(probe_cpu) != 0)
        fprintf(stderr, "warning: could not pin probe to CPU %d\n", probe_cpu);

    /* probe ring */
    mp_buf pbuf = {0, 0, 0};
    void *pp = NULL;
    if (probe) {
        probe_bytes = (probe_bytes / 64) * 64;
        pbuf = mp_alloc(probe_bytes, use_huge);
        memset(pbuf.ptr, 0, probe_bytes);
        build_pointer_ring(pbuf.ptr, probe_bytes / 64, MP_GEN_LCG, seed, &pp, 1);
    }

    /* generators */
    gen_t *gens = calloc(threads ? threads : 1, sizeof *gens);
    pthread_t tid[MAXT];
    pthread_barrier_init(&g_ready, NULL, (unsigned)threads + 1);
    for (int i = 0; i < threads; i++) {
        gen_t *g = &gens[i];
        g->id = i; g->cpu = cpus[i]; g->huge = use_huge; g->kind = kind;
        g->reads10 = reads10; g->chains = chains; g->delay = delay;
        g->bytes = bytes; g->seed = (uint64_t)seed * 1000003u + (uint64_t)i + 1;
        atomic_store(&g_prog[i].progress, 0);
        pthread_create(&tid[i], NULL, gen_thread, g);
    }
    pthread_barrier_wait(&g_ready);
    long ahp = mp_anon_thp_kib();
    double ghz = mp_measure_ghz();   /* on the probe CPU (or unpinned) before load starts */

    mp_imc imc;
    mp_imc_open(&imc, 1);
    mp_imc_start(&imc);
    atomic_store_explicit(&g_go, 1, memory_order_release);
    double dt;
    if (probe) probe_window(&pp, warm_ms / 1000.0, &dt);
    else       sleep_window(warm_ms / 1000.0, &dt);

    if (want_header)
        printf("experiment,kernel,pages,threads,chains,reads10,delay,probe,gen_bytes,probe_bytes,"
               "anon_thp_kib,ghz,rep,time_s,gen_gib_s,total_gib_s,traffic_gib_s,gen_lat_ns,"
               "probe_ns,probe_cycles,little_l,imc_rd_gib_s,imc_wr_gib_s\n");

    const double GiB = 1024.0 * 1024.0 * 1024.0;
    uint64_t p0[MAXT], p1[MAXT];
    for (int r = 0; r < reps; r++) {
        double m0[2], m1[2];
        mp_imc_read(&imc, m0);
        for (int i = 0; i < threads; i++) p0[i] = atomic_load_explicit(&g_prog[i].progress, memory_order_relaxed);
        size_t pacc = 0;
        if (probe) pacc = probe_window(&pp, min_ms / 1000.0, &dt);
        else       sleep_window(min_ms / 1000.0, &dt);
        for (int i = 0; i < threads; i++) p1[i] = atomic_load_explicit(&g_prog[i].progress, memory_order_relaxed);
        mp_imc_read(&imc, m1);

        double gen_units = 0, lat_sum = 0;
        int lat_n = 0;
        for (int i = 0; i < threads; i++) {
            double du = (double)(p1[i] - p0[i]);
            gen_units += du;
            if (kind == G_CHASE && du > 0) { lat_sum += dt * 1e9 / (du / (double)chains); lat_n++; }
        }
        double gen_gib = gen_units * 64.0 / dt / GiB;
        double probe_gib = (double)pacc * 64.0 / dt / GiB;
        double wfac = kind == G_RWMIX ? (reads10 + 2.0 * (10 - reads10)) / 10.0 : 1.0;
        double gen_lat = lat_n ? lat_sum / lat_n : NAN;
        double probe_ns = probe ? dt * 1e9 / (double)pacc : NAN;
        /* chase: generators only, so little_l can be compared with N = T*k;
         * otherwise all lines in flight (generators + probe) at probe latency */
        double lines_per_ns = (gen_units + (kind == G_CHASE ? 0.0 : (double)pacc)) / (dt * 1e9);
        double W = kind == G_CHASE ? gen_lat : probe_ns;
        printf("%s,%s,%s,%d,%d,%d,%d,%d,%zu,%zu,%ld,%.3f,%d,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e\n",
               experiment, gkind_name(kind), mp_pages_name(use_huge), threads,
               kind == G_CHASE ? chains : 0, kind == G_RWMIX ? reads10 : 10, delay, probe,
               bytes, probe ? probe_bytes : (size_t)0, ahp, ghz, r, dt, gen_gib,
               gen_gib + probe_gib, gen_gib * wfac + probe_gib, gen_lat, probe_ns,
               probe_ns * ghz, lines_per_ns * W, (m1[0] - m0[0]) / dt / GiB, (m1[1] - m0[1]) / dt / GiB);
        fflush(stdout);
    }

    mp_imc_close(&imc);
    atomic_store(&g_stop, 1);
    uint64_t s = (uint64_t)(uintptr_t)pp;
    for (int i = 0; i < threads; i++) { pthread_join(tid[i], NULL); s += gens[i].sink; mp_free(gens[i].buf); }
    acs_consume_i64((int64_t)s);
    pthread_barrier_destroy(&g_ready);
    mp_free(pbuf);
    free(gens);
    return 0;
}
