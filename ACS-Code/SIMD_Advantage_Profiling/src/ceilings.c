/*
 * ceilings.c — machine ceilings for the roofline, measured independently of
 * the kernels under study (Project 1).
 *
 *   ceilings --bench peak  --isa <isa>                    peak FLOP rate
 *   ceilings --bench read|copy|triad --bytes B [--label L] streaming bandwidth
 *   common: --reps R --min-ms M --warmup W --cpu C --header --experiment E
 *
 * Peak FLOP rate. A register-only loop with 12 independent accumulators per
 * ISA. On a Skylake-class core FMA (and mul/add) latency is 4 cycles and two
 * ports execute them, so >= 8 independent chains are needed to keep both ports
 * busy every cycle; 12 leaves headroom and still fits the 16 vector registers.
 * No memory is touched, so the result is the core's arithmetic ceiling:
 *   scalar_f32      mulss + addss       (what the scalar build can issue)
 *   scalar_fma_f32  vfmadd231ss         (scalar FMA, 1 lane)
 *   sse_f32         mulps + addps, xmm  (generic x86-64 autovec ISA, 4 lanes, no FMA)
 *   sse_f64         mulpd + addpd, xmm  (2 lanes)
 *   avx2_fma_f32    vfmadd231ps, ymm    (native build, 8 lanes)
 *   avx2_fma_f64    vfmadd231pd, ymm    (4 lanes)
 * Each accumulator update a = a*m + c is counted as 2 FLOP, fused or not.
 *
 * Bandwidth. STREAM-style loops written with AVX2 intrinsics (the widest
 * loads/stores this CPU has), over float32 arrays whose *total* footprint is
 * --bytes, so one binary sweeps L1, L2, L3 and DRAM:
 *   read   s += a[i]            (4 accumulators)     4 B/elem
 *   copy   b[i] = a[i]                                8 B/elem
 *   triad  a[i] = b[i] + s*c[i]                      12 B/elem, 2 FLOP/elem
 * Bytes are counted STREAM-style (explicit loads + stores). A store to a line
 * that was not read first also costs a write-allocate read from the next level;
 * that hidden traffic is reported separately in wa_bytes and NOT included in
 * gib_per_s; gib_per_s_total = (bytes_moved + wa_bytes) / time is the actual
 * traffic and is what the roofline uses (the kernels' arithmetic intensities in
 * the report are counted the same way).
 *
 * Optional user-space cycle counts (perf_event_open, see perfctr.h) give the
 * effective core clock and FLOP/cycle; NA when counters are unavailable.
 *
 * Built once with fixed flags (-O2 -ffp-contract=off, no -march); the AVX2/FMA
 * code paths use function-level target attributes and are only executed after
 * a runtime CPU check.
 */
#define _GNU_SOURCE
#include "common.h"
#include "perfctr.h"

#include <immintrin.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NOINLINE __attribute__((noinline))
#define AVX2 __attribute__((target("avx2,fma"), noinline))
#define NACC 12

/* ------------------------------------------------------------ peak kernels */
/* Each returns a value derived from every accumulator so none is dead. */
#define DECL(T, SET, k) T a##k = SET(1.0 + 0.01 * k);
#define DECL12(T, SET) DECL(T,SET,0) DECL(T,SET,1) DECL(T,SET,2) DECL(T,SET,3) DECL(T,SET,4) \
    DECL(T,SET,5) DECL(T,SET,6) DECL(T,SET,7) DECL(T,SET,8) DECL(T,SET,9) DECL(T,SET,10) DECL(T,SET,11)
#define STEP12(OP) OP(a0) OP(a1) OP(a2) OP(a3) OP(a4) OP(a5) OP(a6) OP(a7) OP(a8) OP(a9) OP(a10) OP(a11)
#define SUM12(ADD) ADD(ADD(ADD(ADD(a0, a1), ADD(a2, a3)), ADD(ADD(a4, a5), ADD(a6, a7))), ADD(ADD(a8, a9), ADD(a10, a11)))

#define SET_SS(v) _mm_set_ss((float)(v))
#define SET_PS(v) _mm_set1_ps((float)(v))
#define SET_PD(v) _mm_set1_pd((double)(v))
#define SET_PS8(v) _mm256_set1_ps((float)(v))
#define SET_PD4(v) _mm256_set1_pd((double)(v))

NOINLINE static double peak_scalar_f32(size_t iters) {
    const __m128 m = SET_SS(0.999999), c = SET_SS(1e-7);
    DECL12(__m128, SET_SS)
#define OP(a) a = _mm_add_ss(_mm_mul_ss(a, m), c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    return _mm_cvtss_f32(SUM12(_mm_add_ss));
}

AVX2 static double peak_scalar_fma_f32(size_t iters) {
    const __m128 m = SET_SS(0.999999), c = SET_SS(1e-7);
    DECL12(__m128, SET_SS)
#define OP(a) a = _mm_fmadd_ss(a, m, c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    return _mm_cvtss_f32(SUM12(_mm_add_ss));
}

NOINLINE static double peak_sse_f32(size_t iters) {
    const __m128 m = SET_PS(0.999999), c = SET_PS(1e-7);
    DECL12(__m128, SET_PS)
#define OP(a) a = _mm_add_ps(_mm_mul_ps(a, m), c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    return _mm_cvtss_f32(SUM12(_mm_add_ps));
}

NOINLINE static double peak_sse_f64(size_t iters) {
    const __m128d m = SET_PD(0.999999), c = SET_PD(1e-7);
    DECL12(__m128d, SET_PD)
#define OP(a) a = _mm_add_pd(_mm_mul_pd(a, m), c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    return _mm_cvtsd_f64(SUM12(_mm_add_pd));
}

AVX2 static double peak_avx2_fma_f32(size_t iters) {
    const __m256 m = SET_PS8(0.999999), c = SET_PS8(1e-7);
    DECL12(__m256, SET_PS8)
#define OP(a) a = _mm256_fmadd_ps(a, m, c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    __m256 s = SUM12(_mm256_add_ps);
    return _mm_cvtss_f32(_mm256_castps256_ps128(s));
}

AVX2 static double peak_avx2_fma_f64(size_t iters) {
    const __m256d m = SET_PD4(0.999999), c = SET_PD4(1e-7);
    DECL12(__m256d, SET_PD4)
#define OP(a) a = _mm256_fmadd_pd(a, m, c);
    for (size_t i = 0; i < iters; i++) { STEP12(OP) }
#undef OP
    __m256d s = SUM12(_mm256_add_pd);
    return _mm_cvtsd_f64(_mm256_castpd256_pd128(s));
}

typedef struct {
    const char *isa;
    double (*fn)(size_t);
    int lanes;     /* elements per accumulator */
    int needs_avx2;
} peak_t;

static const peak_t PEAKS[] = {
    {"scalar_f32",     peak_scalar_f32,     1, 0},
    {"scalar_fma_f32", peak_scalar_fma_f32, 1, 1},
    {"sse_f32",        peak_sse_f32,        4, 0},
    {"sse_f64",        peak_sse_f64,        2, 0},
    {"avx2_fma_f32",   peak_avx2_fma_f32,   8, 1},
    {"avx2_fma_f64",   peak_avx2_fma_f64,   4, 1},
};

/* ------------------------------------------------------------ bandwidth kernels */
/* n is a multiple of 32 floats (4 ymm registers per unrolled step). */
AVX2 static double bw_read(const float *a, size_t n) {
    __m256 s0 = _mm256_setzero_ps(), s1 = s0, s2 = s0, s3 = s0;
    for (size_t i = 0; i < n; i += 32) {
        s0 = _mm256_add_ps(s0, _mm256_load_ps(a + i));
        s1 = _mm256_add_ps(s1, _mm256_load_ps(a + i + 8));
        s2 = _mm256_add_ps(s2, _mm256_load_ps(a + i + 16));
        s3 = _mm256_add_ps(s3, _mm256_load_ps(a + i + 24));
    }
    __m256 s = _mm256_add_ps(_mm256_add_ps(s0, s1), _mm256_add_ps(s2, s3));
    return _mm_cvtss_f32(_mm256_castps256_ps128(s));
}

AVX2 static double bw_copy(const float *a, float *b, size_t n) {
    for (size_t i = 0; i < n; i += 32) {
        _mm256_store_ps(b + i,      _mm256_load_ps(a + i));
        _mm256_store_ps(b + i + 8,  _mm256_load_ps(a + i + 8));
        _mm256_store_ps(b + i + 16, _mm256_load_ps(a + i + 16));
        _mm256_store_ps(b + i + 24, _mm256_load_ps(a + i + 24));
    }
    return b[n / 2];
}

AVX2 static double bw_triad(float *a, const float *b, const float *c, float s, size_t n) {
    const __m256 vs = _mm256_set1_ps(s);
    for (size_t i = 0; i < n; i += 32) {
        _mm256_store_ps(a + i,      _mm256_fmadd_ps(vs, _mm256_load_ps(c + i),      _mm256_load_ps(b + i)));
        _mm256_store_ps(a + i + 8,  _mm256_fmadd_ps(vs, _mm256_load_ps(c + i + 8),  _mm256_load_ps(b + i + 8)));
        _mm256_store_ps(a + i + 16, _mm256_fmadd_ps(vs, _mm256_load_ps(c + i + 16), _mm256_load_ps(b + i + 16)));
        _mm256_store_ps(a + i + 24, _mm256_fmadd_ps(vs, _mm256_load_ps(c + i + 24), _mm256_load_ps(b + i + 24)));
    }
    return a[n / 2];
}

/* ------------------------------------------------------------ driver */
typedef enum { B_PEAK, B_READ, B_COPY, B_TRIAD } bench_t;

typedef struct {
    bench_t bench;
    const peak_t *peak;
    float *a, *b, *c;
    size_t n;
} job_t;

static double run_job(const job_t *j, size_t iters) {
    double sink = 0.0;
    if (j->bench == B_PEAK)
        return j->peak->fn(iters);
    for (size_t k = 0; k < iters; k++) {
        switch (j->bench) {
        case B_READ:  sink += bw_read(j->a, j->n); break;
        case B_COPY:  sink += bw_copy(j->a, j->b, j->n); break;
        default:      sink += bw_triad(j->a, j->b, j->c, 0.5f, j->n); break;
        }
    }
    return sink;
}

/* Peak kernels take their loop count directly; bandwidth kernels count passes. */
static size_t calibrate(const job_t *j, double min_s) {
    size_t iters = j->bench == B_PEAK ? 1024 : 1;
    for (;;) {
        double t0 = acs_now_sec();
        acs_consume_f64(run_job(j, iters));
        double dt = acs_now_sec() - t0;
        if (dt >= min_s || iters >= ((size_t)1 << 40))
            return iters;
        if (dt < 1e-6) { iters *= 8; continue; }
        double f = (min_s * 1.3) / dt;
        size_t next = (size_t)((double)iters * (f < 2.0 ? 2.0 : f));
        iters = next > iters ? next : iters * 2;
    }
}

static void print_na(double v, const char *fmt) {
    putchar(',');
    if (isnan(v) || isinf(v)) fputs("NA", stdout);
    else printf(fmt, v);
}

static void usage(void) {
    fprintf(stderr,
            "usage: ceilings --bench peak --isa {scalar_f32|scalar_fma_f32|sse_f32|sse_f64|avx2_fma_f32|avx2_fma_f64}\n"
            "       ceilings --bench {read|copy|triad} --bytes <total footprint> [--label L]\n"
            "       [--reps R] [--min-ms M] [--warmup W] [--cpu C] [--experiment E] [--header]\n");
}

int main(int argc, char **argv) {
    const char *bench_s = NULL, *isa = "avx2", *label = "-", *experiment = "ceilings";
    size_t bytes = 0;
    int reps = 10, warmup = 2, cpu = -1, header = 0;
    double min_ms = 20.0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc && strcmp(a, "--header")) { usage(); return 2; }
        if (!strcmp(a, "--bench")) bench_s = argv[++i];
        else if (!strcmp(a, "--isa")) isa = argv[++i];
        else if (!strcmp(a, "--bytes")) bytes = strtoull(argv[++i], 0, 0);
        else if (!strcmp(a, "--label")) label = argv[++i];
        else if (!strcmp(a, "--reps")) reps = atoi(argv[++i]);
        else if (!strcmp(a, "--min-ms")) min_ms = atof(argv[++i]);
        else if (!strcmp(a, "--warmup")) warmup = atoi(argv[++i]);
        else if (!strcmp(a, "--cpu")) cpu = atoi(argv[++i]);
        else if (!strcmp(a, "--experiment")) experiment = argv[++i];
        else if (!strcmp(a, "--header")) header = 1;
        else { usage(); return 2; }
    }
    if (!bench_s) { usage(); return 2; }

    __builtin_cpu_init();
    int have_avx2 = __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");

    job_t j;
    memset(&j, 0, sizeof j);
    acs_buf ba = {0, 0}, bb = {0, 0}, bc = {0, 0};
    double flops_per_pass = 0.0, bytes_per_pass = 0.0, wa_per_pass = 0.0;

    if (!strcmp(bench_s, "peak")) {
        j.bench = B_PEAK;
        for (size_t k = 0; k < sizeof PEAKS / sizeof PEAKS[0]; k++)
            if (!strcmp(PEAKS[k].isa, isa)) j.peak = &PEAKS[k];
        if (!j.peak) { fprintf(stderr, "unknown --isa %s\n", isa); usage(); return 2; }
        if (j.peak->needs_avx2 && !have_avx2) {
            fprintf(stderr, "ceilings: CPU lacks AVX2/FMA; skipping %s\n", isa);
            return 3;
        }
        flops_per_pass = 2.0 * NACC * j.peak->lanes;   /* per loop iteration */
        j.n = (size_t)NACC * j.peak->lanes;
    } else {
        int arrays;
        if (!strcmp(bench_s, "read"))       { j.bench = B_READ;  arrays = 1; }
        else if (!strcmp(bench_s, "copy"))  { j.bench = B_COPY;  arrays = 2; }
        else if (!strcmp(bench_s, "triad")) { j.bench = B_TRIAD; arrays = 3; }
        else { fprintf(stderr, "unknown --bench %s\n", bench_s); usage(); return 2; }
        if (!have_avx2) { fprintf(stderr, "ceilings: CPU lacks AVX2/FMA\n"); return 3; }
        if (bytes == 0) { fprintf(stderr, "--bytes is required for %s\n", bench_s); return 2; }
        size_t n = bytes / ((size_t)arrays * sizeof(float));
        n -= n % 32;
        if (n < 32) n = 32;
        j.n = n;
        ba = acs_alloc(n * sizeof(float), 64, 0);
        j.a = ba.ptr;
        for (size_t i = 0; i < n; i++) j.a[i] = 1.0f + (float)(i & 7) * 0.125f;
        if (arrays >= 2) {
            bb = acs_alloc(n * sizeof(float), 64, 0);
            j.b = bb.ptr;
            for (size_t i = 0; i < n; i++) j.b[i] = 0.5f;
        }
        if (arrays >= 3) {
            bc = acs_alloc(n * sizeof(float), 64, 0);
            j.c = bc.ptr;
            for (size_t i = 0; i < n; i++) j.c[i] = 0.25f;
        }
        bytes = (size_t)arrays * n * sizeof(float);       /* actual footprint */
        bytes_per_pass = (double)bytes;                   /* each array touched once */
        wa_per_pass = (j.bench == B_READ) ? 0.0 : (double)(n * sizeof(float));
        flops_per_pass = (j.bench == B_TRIAD) ? 2.0 * (double)n : 0.0;
        isa = "avx2";
    }

    if (cpu >= 0 && acs_pin_cpu(cpu) != 0)
        fprintf(stderr, "warning: could not pin to CPU %d\n", cpu);

    for (int w = 0; w < warmup; w++)
        acs_consume_f64(run_job(&j, j.bench == B_PEAK ? 1u << 20 : 1));
    size_t iters = calibrate(&j, min_ms / 1000.0);

    acs_perf perf;
    acs_perf_open(&perf);

    if (header)
        printf("experiment,bench,isa,label,bytes,n,rep,iters,time_s,flops,gflops,"
               "bytes_moved,gib_per_s,gb_per_s,wa_bytes,gib_per_s_total,cycles,ghz,flops_per_cycle,bytes_per_cycle\n");

    for (int r = 0; r < reps; r++) {
        double ctr[PC_N];
        acs_perf_start(&perf);
        double t0 = acs_now_sec();
        double sink = run_job(&j, iters);
        double dt = acs_now_sec() - t0;
        acs_perf_stop(&perf, ctr);
        acs_consume_f64(sink);

        double flops = flops_per_pass * (double)iters;
        double moved = bytes_per_pass * (double)iters;
        double cyc = ctr[PC_CYCLES];
        double wa = wa_per_pass * (double)iters;
        printf("%s,%s,%s,%s,%zu,%zu,%d,%zu,%.9e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e",
               experiment, bench_s, isa, label, bytes, j.n, r, iters, dt,
               flops, flops / dt / 1e9, moved, moved / dt / 1073741824.0, moved / dt / 1e9,
               wa, (moved + wa) / dt / 1073741824.0);
        print_na(cyc, "%.0f");
        print_na(cyc / dt / 1e9, "%.4f");
        print_na(flops / cyc, "%.4f");
        print_na(moved / cyc, "%.4f");
        putchar('\n');
    }

    acs_perf_close(&perf);
    if (ba.base) acs_free(ba);
    if (bb.base) acs_free(bb);
    if (bc.base) acs_free(bc);
    return 0;
}
