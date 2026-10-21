/*
 * memprof.h — helpers shared by the Project 2 benchmarks (header-only).
 *
 *   mp_measure_ghz()    effective core GHz from a dependent add chain
 *   mp_tsc_ghz()        TSC rate calibrated against CLOCK_MONOTONIC_RAW
 *   mp_alloc()/mp_free  2 MiB-aligned anonymous mmap with an explicit page policy:
 *                       huge=1 -> madvise(MADV_HUGEPAGE) before first touch,
 *                       huge=0 -> madvise(MADV_NOHUGEPAGE) so "4k" really is 4 KiB
 *                       even though THP is set to `always` on the test host.
 *   mp_anon_thp_kib()   AnonHugePages actually granted (from /proc/self/smaps_rollup)
 *   mp_sattolo()        single-cycle random permutation with a selectable PRNG
 *   mp_ctr_*            user-space hardware counters through perf_event_open(2).
 *
 * Counters: the host has perf_event_paranoid=2 and no `perf` binary, but a process
 * may still count its own user-space events (exclude_kernel=1, exclude_hv=1). We
 * open each event as an independent counter (not a group) so the kernel can
 * multiplex them if fewer hardware counters are free; values are scaled by
 * time_enabled/time_running and the minimum running fraction is reported as
 * `ctr_cover` so readers can see whether multiplexing happened. Any event that
 * cannot be opened is reported as `nan` (pgfplots and derive.py skip it).
 *
 * Kept project-local (not in ../common) because only Project 2 uses it.
 */
#ifndef MEMPROF_H
#define MEMPROF_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "common.h"

#include <linux/perf_event.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <x86intrin.h>
#endif

#define MP_HUGE_ALIGN ((size_t)2 * 1024 * 1024)

/* ------------------------------------------------------------ frequency */
/* Add-chain frequency probe: one dependent ADD per iteration, iterations / wall second.
 * CAUTION (see clock_check.c and the report): this is NOT a reliable clock measurement.
 * It assumes the loop runs at exactly 1 iteration/cycle (code-alignment dependent) and that
 * the thread owns all of the wall time; on the test host ~1/3 of 0.3 s windows lose ~13% of
 * wall time to ACPI GPE bursts, so it reads ~2.41 instead of ~2.79 GHz. The analysis
 * converts ns -> cycles with the fixed 2.8 GHz clock instead (scripts/derive.py). */
static inline double mp_measure_ghz(void) {
    uint64_t a = 1, n = 1000000000ull;
    double t0 = acs_now_sec();
#if defined(__x86_64__)
    __asm__ volatile("1:\n\t add $1, %[a]\n\t sub $1, %[n]\n\t jnz 1b\n\t"
                     : [a] "+r"(a), [n] "+r"(n)::"cc");
#else
    for (volatile uint64_t i = 0; i < n; i++) a += 1;
#endif
    double dt = acs_now_sec() - t0;
    acs_consume_i64((int64_t)a);
    return 1000000000.0 / dt / 1e9;
}

static inline uint64_t mp_rdtsc(void) {
#if defined(__x86_64__)
    unsigned aux;
    return __rdtscp(&aux);
#else
    return (uint64_t)(acs_now_sec() * 1e9);
#endif
}

/* TSC ticks per ns, calibrated over ~50 ms of the monotonic raw clock. */
static inline double mp_tsc_ghz(void) {
    double t0 = acs_now_sec();
    uint64_t c0 = mp_rdtsc();
    while (acs_now_sec() - t0 < 0.05) { }
    uint64_t c1 = mp_rdtsc();
    double t1 = acs_now_sec();
    return (double)(c1 - c0) / ((t1 - t0) * 1e9);
}

/* ------------------------------------------------------------ memory */
typedef struct {
    void  *map;      /* what to munmap */
    size_t map_len;
    void  *ptr;      /* 2 MiB-aligned usable pointer */
} mp_buf;

static inline mp_buf mp_alloc(size_t bytes, int huge) {
    mp_buf b = {0, 0, 0};
    size_t len = ((bytes + MP_HUGE_ALIGN - 1) / MP_HUGE_ALIGN) * MP_HUGE_ALIGN;
    b.map_len = len + MP_HUGE_ALIGN;
    b.map = mmap(NULL, b.map_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (b.map == MAP_FAILED) {
        fprintf(stderr, "mp_alloc: mmap of %zu bytes failed\n", b.map_len);
        exit(1);
    }
    uintptr_t p = ((uintptr_t)b.map + MP_HUGE_ALIGN - 1) & ~(uintptr_t)(MP_HUGE_ALIGN - 1);
    b.ptr = (void *)p;
    /* Must happen before first touch: THP decides the page size at fault time. */
    if (madvise(b.ptr, len, huge ? MADV_HUGEPAGE : MADV_NOHUGEPAGE) != 0)
        fprintf(stderr, "mp_alloc: madvise(%s) failed\n", huge ? "HUGEPAGE" : "NOHUGEPAGE");
    return b;
}

static inline void mp_free(mp_buf b) {
    if (b.map) munmap(b.map, b.map_len);
}

/* AnonHugePages (KiB) backing this process; -1 if unreadable. Read after the
 * buffers are touched to record what the kernel actually granted. */
static inline long mp_anon_thp_kib(void) {
    FILE *f = fopen("/proc/self/smaps_rollup", "r");
    if (!f) return -1;
    char line[256];
    long v = -1;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "AnonHugePages: %ld kB", &v) == 1) break;
    fclose(f);
    return v;
}

static inline int mp_parse_pages(const char *s) { return !strcmp(s, "huge") || !strcmp(s, "2m"); }

/* ------------------------------------------------------------ permutations */
/* gen 0 = "lcg": 32-bit LCG (Numerical Recipes constants), `s % i` (the
 *         generator used since the first version of mem_latency);
 * gen 1 = "xorshift": xorshift64* with Lemire's multiply-shift range reduction.
 * The second generator exists so the zero-queue numbers can be cross-checked
 * with an independently constructed ring (Intel MLC is not available). */
typedef enum { MP_GEN_LCG = 0, MP_GEN_XORSHIFT = 1 } mp_gen_t;

static inline const char *mp_gen_name(mp_gen_t g) { return g == MP_GEN_XORSHIFT ? "xorshift" : "lcg"; }

/* Fill order[0..n-1] with a permutation; Sattolo's variant (j < i) makes the
 * successor map order[k] -> order[k+1] a single cycle over all n nodes. */
static inline void mp_sattolo(size_t *order, size_t n, mp_gen_t gen, uint64_t seed) {
    for (size_t k = 0; k < n; k++) order[k] = k;
    if (n < 2) return;
    uint32_t s32 = (uint32_t)seed;
    uint64_t s64 = seed ? seed * 0x9E3779B97F4A7C15ull : 0x2545F4914F6CDD1Dull;
    for (size_t i = n - 1; i > 0; i--) {
        size_t j;
        if (gen == MP_GEN_LCG) {
            s32 = s32 * 1664525u + 1013904223u;
            j = s32 % i;
        } else {
            s64 ^= s64 >> 12; s64 ^= s64 << 25; s64 ^= s64 >> 27;
            uint64_t r = s64 * 0x2545F4914F6CDD1Dull;
            j = (size_t)(((unsigned __int128)r * i) >> 64);
        }
        size_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
}

/* ------------------------------------------------------------ counters */
enum { MP_CYCLES, MP_INSTR, MP_L1D_MISS, MP_LLC_REF, MP_LLC_MISS, MP_DTLB_MISS, MP_NCTR };

static const char *const mp_ctr_names[MP_NCTR] = {
    "cycles", "instr", "l1d_miss", "llc_ref", "llc_miss", "dtlb_miss"};

typedef struct {
    int fd[MP_NCTR];
    int enabled;
} mp_ctr;

static inline int mp_perf_open(uint32_t type, uint64_t config) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = type;
    a.config = config;
    a.disabled = 1;
    a.exclude_kernel = 1;   /* required at perf_event_paranoid=2 */
    a.exclude_hv = 1;
    a.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
    return (int)syscall(SYS_perf_event_open, &a, 0 /* this thread */, -1, -1, 0);
}

#define MP_HWC(cache, op, res) \
    ((uint64_t)(cache) | ((uint64_t)(op) << 8) | ((uint64_t)(res) << 16))

/* Open the six events for the calling thread. Events that fail stay at -1. */
static inline void mp_ctr_open(mp_ctr *c, int want) {
    for (int i = 0; i < MP_NCTR; i++) c->fd[i] = -1;
    c->enabled = want;
    if (!want) return;
    c->fd[MP_CYCLES]   = mp_perf_open(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES);
    c->fd[MP_INSTR]    = mp_perf_open(PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS);
    c->fd[MP_L1D_MISS] = mp_perf_open(PERF_TYPE_HW_CACHE,
        MP_HWC(PERF_COUNT_HW_CACHE_L1D, PERF_COUNT_HW_CACHE_OP_READ, PERF_COUNT_HW_CACHE_RESULT_MISS));
    c->fd[MP_LLC_REF]  = mp_perf_open(PERF_TYPE_HW_CACHE,
        MP_HWC(PERF_COUNT_HW_CACHE_LL, PERF_COUNT_HW_CACHE_OP_READ, PERF_COUNT_HW_CACHE_RESULT_ACCESS));
    c->fd[MP_LLC_MISS] = mp_perf_open(PERF_TYPE_HW_CACHE,
        MP_HWC(PERF_COUNT_HW_CACHE_LL, PERF_COUNT_HW_CACHE_OP_READ, PERF_COUNT_HW_CACHE_RESULT_MISS));
    c->fd[MP_DTLB_MISS] = mp_perf_open(PERF_TYPE_HW_CACHE,
        MP_HWC(PERF_COUNT_HW_CACHE_DTLB, PERF_COUNT_HW_CACHE_OP_READ, PERF_COUNT_HW_CACHE_RESULT_MISS));
    int any = 0;
    for (int i = 0; i < MP_NCTR; i++) any |= (c->fd[i] >= 0);
    if (!any) fprintf(stderr, "note: perf_event_open unavailable; counter columns = nan\n");
}

static inline void mp_ctr_start(mp_ctr *c) {
    for (int i = 0; i < MP_NCTR; i++)
        if (c->fd[i] >= 0) {
            ioctl(c->fd[i], PERF_EVENT_IOC_RESET, 0);
            ioctl(c->fd[i], PERF_EVENT_IOC_ENABLE, 0);
        }
}

/* Stop and read scaled counts into out[] (nan when unavailable). *cover receives
 * the smallest time_running/time_enabled over the open events (1 = no
 * multiplexing), or nan when no event is open. */
static inline void mp_ctr_stop(mp_ctr *c, double out[MP_NCTR], double *cover) {
    double cov = NAN;
    for (int i = 0; i < MP_NCTR; i++) {
        out[i] = NAN;
        if (c->fd[i] < 0) continue;
        ioctl(c->fd[i], PERF_EVENT_IOC_DISABLE, 0);
        uint64_t v[3] = {0, 0, 0};
        if (read(c->fd[i], v, sizeof v) != (ssize_t)sizeof v || v[2] == 0) continue;
        out[i] = (double)v[0] * ((double)v[1] / (double)v[2]);
        double f = (double)v[2] / (double)v[1];
        if (isnan(cov) || f < cov) cov = f;
    }
    if (cover) *cover = cov;
}

static inline void mp_ctr_close(mp_ctr *c) {
    for (int i = 0; i < MP_NCTR; i++)
        if (c->fd[i] >= 0) close(c->fd[i]);
}

/* Print ",ctr_<name>_<suffix>..." header fields and the matching values. */
static inline void mp_ctr_header(const char *suffix) {
    for (int i = 0; i < MP_NCTR; i++) printf(",ctr_%s_%s", mp_ctr_names[i], suffix);
    printf(",ctr_cover");
}
static inline void mp_ctr_print(const double v[MP_NCTR], double cover, double per) {
    for (int i = 0; i < MP_NCTR; i++) {
        if (isnan(v[i]) || per <= 0) printf(",nan");
        else printf(",%.6e", v[i] / per);
    }
    if (isnan(cover)) printf(",nan"); else printf(",%.4f", cover);
}

#endif /* MEMPROF_H */
