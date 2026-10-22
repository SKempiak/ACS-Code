/*
 * main.c — benchmark driver for the SIMD kernels (Project 1).
 *
 * One invocation measures ONE configuration (kernel, dtype, N, alignment
 * offset, access pattern) and prints raw CSV rows, one per repetition, to
 * stdout. scripts/run.sh sweeps the knobs by invoking this binary many times
 * and concatenating the rows; tools/summarize.c then reduces them.
 *
 * Measurement discipline:
 *   - monotonic raw timer (common.c);
 *   - optional CPU pinning (--cpu);
 *   - warm-up passes, then a calibrated batch of >= --min-ms per repetition so
 *     the timed interval dwarfs the timer resolution;
 *   - every kernel result is consumed through a volatile sink so the optimizer
 *     cannot delete the timed loop (see the AI-use note / RESULTS.md for the
 *     dead-code-elimination correction this guards against);
 *   - output is validated against src/reference.c before timing unless
 *     --no-check is given.
 *
 * The harness (this file + common.c + reference.c) is compiled with fixed flags
 * in every build variant; only kernels.c changes. So a difference in timing is
 * a difference in the kernel's code generation, not the driver's.
 */
#define _GNU_SOURCE
#include "common.h"
#include "kernels.h"
#include "perfctr.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ----------------------------------------------------- config */
typedef enum { DT_F32, DT_F64, DT_I32 } dtype_t;
typedef enum { ACC_UNIT, ACC_STRIDE, ACC_GATHER, ACC_GATHER_AVX2 } access_t;

typedef struct {
    const char *kernel;   /* saxpy | dot | mul | stencil */
    dtype_t     dtype;
    access_t    access;
    size_t      n;        /* number of processed elements */
    size_t      stride;   /* for ACC_STRIDE */
    size_t      offset;   /* start offset in bytes from an aligned base */
    int         reps;
    double      min_ms;
    int         warmup;
    int         cpu;
    unsigned    seed;
    int         do_check;
    const char *experiment;
    int         counters; /* append user-space hardware-counter columns */
} config_t;

static int is_gather(access_t a) { return a == ACC_GATHER || a == ACC_GATHER_AVX2; }

static const char *dtype_name(dtype_t d) {
    switch (d) {
    case DT_F32: return "f32";
    case DT_F64: return "f64";
    default:     return "i32";
    }
}
static const char *access_name(access_t a) {
    switch (a) {
    case ACC_UNIT:   return "unit";
    case ACC_STRIDE: return "stride";
    case ACC_GATHER: return "gather";
    default:         return "gather_avx2";
    }
}

/* FLOPs (or integer ops) per processed element, documented in the report. */
static double flops_per_elem(const char *k) {
    if (!strcmp(k, "saxpy"))   return 2.0; /* one mul + one add (one FMA)   */
    if (!strcmp(k, "dot"))     return 2.0; /* one mul + one add (one FMA)   */
    if (!strcmp(k, "mul"))     return 1.0; /* one multiply                  */
    if (!strcmp(k, "stencil")) return 5.0; /* three mul + two add           */
    return 0.0;
}

/* ----------------------------------------------------- data */
/* All buffers for one run. Only the fields the config needs are allocated. */
typedef struct {
    acs_buf x, y, z, yref, idx;
    size_t  span; /* allocated elements per array (n or n*stride) */
} data_t;

static void fill_f32(float *a, size_t n, unsigned seed) {
    unsigned s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;          /* LCG */
        a[i] = (float)((s >> 8) & 0xffff) / 65536.0f - 0.5f; /* [-0.5,0.5) */
    }
}
static void fill_f64(double *a, size_t n, unsigned seed) {
    unsigned s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        a[i] = (double)((s >> 8) & 0xffff) / 65536.0 - 0.5;
    }
}
static void fill_i32(int32_t *a, size_t n, unsigned seed) {
    unsigned s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        a[i] = (int32_t)((s >> 16) & 0x3ff) - 512; /* small, no overflow */
    }
}

/* A shuffled index permutation of [0,n) for the gather pattern. */
static void fill_perm(int32_t *idx, size_t n, unsigned seed) {
    for (size_t i = 0; i < n; i++)
        idx[i] = (int32_t)i;
    unsigned s = seed;
    for (size_t i = n; i > 1; i--) {
        s = s * 1664525u + 1013904223u;
        size_t j = s % i;
        int32_t t = idx[i - 1];
        idx[i - 1] = idx[j];
        idx[j] = t;
    }
}

static size_t elem_size(dtype_t d) { return d == DT_F64 ? 8 : 4; }

static data_t alloc_data(const config_t *c) {
    data_t d;
    memset(&d, 0, sizeof d);
    size_t span = c->n;
    if (c->access == ACC_STRIDE)
        span = c->n * c->stride;
    d.span = span;
    size_t es = elem_size(c->dtype);
    size_t bytes = span * es;
    size_t align = 64;

    d.x = acs_alloc(bytes, align, c->offset);
    d.y = acs_alloc(bytes, align, c->offset);
    d.yref = acs_alloc(bytes, align, c->offset);
    int needs_z = !strcmp(c->kernel, "mul");
    if (needs_z)
        d.z = acs_alloc(bytes, align, c->offset);
    if (is_gather(c->access))
        d.idx = acs_alloc(c->n * sizeof(int32_t), align, 0);

    if (c->dtype == DT_F32) {
        fill_f32(d.x.ptr, span, c->seed);
        fill_f32(d.y.ptr, span, c->seed ^ 0x9e3779b9u);
    } else if (c->dtype == DT_F64) {
        fill_f64(d.x.ptr, span, c->seed);
        fill_f64(d.y.ptr, span, c->seed ^ 0x9e3779b9u);
    } else {
        fill_i32(d.x.ptr, span, c->seed);
        fill_i32(d.y.ptr, span, c->seed ^ 0x9e3779b9u);
    }
    if (is_gather(c->access))
        fill_perm(d.idx.ptr, c->n, c->seed ^ 0x51ed2701u);
    return d;
}

static void free_data(data_t *d) {
    acs_free(d->x);
    acs_free(d->y);
    acs_free(d->yref);
    if (d->z.base) acs_free(d->z);
    if (d->idx.base) acs_free(d->idx);
}

/* Reset y to its initial contents (SAXPY accumulates; stencil/mul overwrite). */
static void reset_y(const config_t *c, data_t *d) {
    if (c->dtype == DT_F32)
        fill_f32(d->y.ptr, d->span, c->seed ^ 0x9e3779b9u);
    else if (c->dtype == DT_F64)
        fill_f64(d->y.ptr, d->span, c->seed ^ 0x9e3779b9u);
    else
        fill_i32(d->y.ptr, d->span, c->seed ^ 0x9e3779b9u);
}

/* ----------------------------------------------------- dispatch */
/* Run the configured kernel once; return a value to consume as a sink. */
static double run_kernel(const config_t *c, data_t *d) {
    const char *k = c->kernel;
    size_t n = c->n;
    if (c->access == ACC_STRIDE)
        return (saxpy_f32_stride(0.5f, d->x.ptr, d->y.ptr, n, c->stride), 0.0);
    if (c->access == ACC_GATHER)
        return (saxpy_f32_gather(0.5f, d->x.ptr, d->y.ptr, d->idx.ptr, n), 0.0);
    if (c->access == ACC_GATHER_AVX2)
        return (saxpy_f32_gather_avx2(0.5f, d->x.ptr, d->y.ptr, d->idx.ptr, n), 0.0);

    if (c->dtype == DT_F32) {
        if (!strcmp(k, "saxpy")) { saxpy_f32(0.5f, d->x.ptr, d->y.ptr, n); return 0.0; }
        if (!strcmp(k, "dot"))   return (double)dot_f32(d->x.ptr, d->y.ptr, n);
        if (!strcmp(k, "mul"))   { mul_f32(d->x.ptr, d->y.ptr, d->z.ptr, n); return 0.0; }
        if (!strcmp(k, "stencil")){ stencil_f32(0.25f, 0.5f, 0.25f, d->x.ptr, d->y.ptr, n); return 0.0; }
    } else if (c->dtype == DT_F64) {
        if (!strcmp(k, "saxpy")) { saxpy_f64(0.5, d->x.ptr, d->y.ptr, n); return 0.0; }
        if (!strcmp(k, "dot"))   return dot_f64(d->x.ptr, d->y.ptr, n);
        if (!strcmp(k, "mul"))   { mul_f64(d->x.ptr, d->y.ptr, d->z.ptr, n); return 0.0; }
        if (!strcmp(k, "stencil")){ stencil_f64(0.25, 0.5, 0.25, d->x.ptr, d->y.ptr, n); return 0.0; }
    } else { /* i32: only mul */
        if (!strcmp(k, "mul"))   { mul_i32(d->x.ptr, d->y.ptr, d->z.ptr, n); return 0.0; }
    }
    fprintf(stderr, "unknown kernel/dtype combination: %s/%s\n", k, dtype_name(c->dtype));
    exit(2);
}

/* ----------------------------------------------------- validation */
/* Returns max absolute (dot) or relative (arrays) error vs. reference. */
static int validate(const config_t *c, data_t *d, double *out_err) {
    size_t n = c->n;
    double err = 0.0;
    const double tol = (c->dtype == DT_F64) ? 1e-12 : 1e-5;

    reset_y(c, d);
    if (c->access == ACC_STRIDE) {
        acs_buf yk = acs_alloc(d->span * sizeof(float), 64, c->offset);
        memcpy(yk.ptr, d->y.ptr, d->span * sizeof(float));
        saxpy_f32_stride(0.5f, d->x.ptr, yk.ptr, n, c->stride);
        saxpy_f32_stride_ref(0.5f, d->x.ptr, d->y.ptr, n, c->stride);
        for (size_t i = 0; i < n; i++) {
            float a = ((float *)yk.ptr)[i * c->stride], b = ((float *)d->y.ptr)[i * c->stride];
            double e = fabs(a - b) / (fabs(b) + 1e-30);
            if (e > err) err = e;
        }
        acs_free(yk);
    } else if (is_gather(c->access)) {
        acs_buf yk = acs_alloc(n * sizeof(float), 64, c->offset);
        memcpy(yk.ptr, d->y.ptr, n * sizeof(float));
        if (c->access == ACC_GATHER_AVX2)
            saxpy_f32_gather_avx2(0.5f, d->x.ptr, yk.ptr, d->idx.ptr, n);
        else
            saxpy_f32_gather(0.5f, d->x.ptr, yk.ptr, d->idx.ptr, n);
        saxpy_f32_gather_ref(0.5f, d->x.ptr, d->y.ptr, d->idx.ptr, n);
        for (size_t i = 0; i < n; i++) {
            float a = ((float *)yk.ptr)[i], b = ((float *)d->y.ptr)[i];
            double e = fabs(a - b) / (fabs(b) + 1e-30);
            if (e > err) err = e;
        }
        acs_free(yk);
    } else if (!strcmp(c->kernel, "dot")) {
        if (c->dtype == DT_F32) {
            float a = dot_f32(d->x.ptr, d->y.ptr, n), b = dot_f32_ref(d->x.ptr, d->y.ptr, n);
            err = fabs((double)a - (double)b) / (fabs((double)b) + 1e-30);
        } else {
            double a = dot_f64(d->x.ptr, d->y.ptr, n), b = dot_f64_ref(d->x.ptr, d->y.ptr, n);
            err = fabs(a - b) / (fabs(b) + 1e-30);
        }
    } else {
        /* saxpy / mul / stencil: compare the output array to the reference. */
        size_t es = elem_size(c->dtype);
        acs_buf outk = acs_alloc(d->span * es, 64, c->offset);
        acs_buf outr = acs_alloc(d->span * es, 64, c->offset);
        /* fresh y for both */
        reset_y(c, d);
        memcpy(outk.ptr, d->y.ptr, d->span * es);
        memcpy(outr.ptr, d->y.ptr, d->span * es);

        if (c->dtype == DT_F32) {
            float *xk = d->x.ptr, *ok = outk.ptr, *orf = outr.ptr;
            if (!strcmp(c->kernel, "saxpy")) { saxpy_f32(0.5f, xk, ok, n); saxpy_f32_ref(0.5f, xk, orf, n); }
            else if (!strcmp(c->kernel, "mul")) { mul_f32(xk, d->y.ptr, ok, n); mul_f32_ref(xk, d->y.ptr, orf, n); }
            else { stencil_f32(0.25f, 0.5f, 0.25f, xk, ok, n); stencil_f32_ref(0.25f, 0.5f, 0.25f, xk, orf, n); }
            for (size_t i = 0; i < n; i++) { double e = fabs((double)ok[i] - (double)orf[i]) / (fabs((double)orf[i]) + 1e-30); if (e > err) err = e; }
        } else if (c->dtype == DT_F64) {
            double *xk = d->x.ptr, *ok = outk.ptr, *orf = outr.ptr;
            if (!strcmp(c->kernel, "saxpy")) { saxpy_f64(0.5, xk, ok, n); saxpy_f64_ref(0.5, xk, orf, n); }
            else if (!strcmp(c->kernel, "mul")) { mul_f64(xk, d->y.ptr, ok, n); mul_f64_ref(xk, d->y.ptr, orf, n); }
            else { stencil_f64(0.25, 0.5, 0.25, xk, ok, n); stencil_f64_ref(0.25, 0.5, 0.25, xk, orf, n); }
            for (size_t i = 0; i < n; i++) { double e = fabs(ok[i] - orf[i]) / (fabs(orf[i]) + 1e-30); if (e > err) err = e; }
        } else {
            int32_t *xk = d->x.ptr, *ok = outk.ptr, *orf = outr.ptr;
            mul_i32(xk, d->y.ptr, ok, n); mul_i32_ref(xk, d->y.ptr, orf, n);
            for (size_t i = 0; i < n; i++) if (ok[i] != orf[i]) err = 1.0;
        }
        acs_free(outk);
        acs_free(outr);
    }
    *out_err = err;
    return err <= tol;
}

/* ----------------------------------------------------- timing */
static size_t calibrate_iters(const config_t *c, data_t *d, double min_s) {
    size_t iters = 1;
    for (;;) {
        double t0 = acs_now_sec();
        for (size_t k = 0; k < iters; k++)
            acs_consume_f64(run_kernel(c, d));
        double dt = acs_now_sec() - t0;
        if (dt >= min_s || iters >= (size_t)1 << 30)
            return iters < 1 ? 1 : iters;
        if (dt < 1e-6) { iters *= 8; continue; }
        /* scale to reach ~1.3x min_s, then round up */
        double factor = (min_s * 1.3) / dt;
        size_t next = (size_t)(iters * (factor < 2.0 ? 2.0 : factor));
        iters = next > iters ? next : iters * 2;
    }
}

/* Print ",<value>" or ",NA" for an unavailable (NAN) counter-derived value. */
static void print_na(double v, const char *fmt) {
    putchar(',');
    if (isnan(v) || isinf(v)) fputs("NA", stdout);
    else printf(fmt, v);
}

/* ----------------------------------------------------- self-test */
/* Known-answer checks that do not depend on reference.c, run against the
 * variant's own kernels. Returns the number of failures. */
static int selftest(void) {
    enum { N = 1000 };
    int fails = 0;
    float xf[N], yf[N], zf[N];
    double xd[N], yd[N];

    /* dot of all-ones == N */
    for (int i = 0; i < N; i++) { xf[i] = 1.0f; yf[i] = 1.0f; }
    if (fabs((double)dot_f32(xf, yf, N) - (double)N) > 1e-3) {
        fprintf(stderr, "selftest[%s] dot_f32(ones)=%g != %d\n", acs_variant_name(), (double)dot_f32(xf, yf, N), N); fails++; }
    for (int i = 0; i < N; i++) { xd[i] = 1.0; yd[i] = 1.0; }
    if (fabs(dot_f64(xd, yd, N) - (double)N) > 1e-9) {
        fprintf(stderr, "selftest[%s] dot_f64(ones) wrong\n", acs_variant_name()); fails++; }

    /* saxpy: y = 2*x + y with x=1, y=3 -> 5 everywhere */
    for (int i = 0; i < N; i++) { xf[i] = 1.0f; yf[i] = 3.0f; }
    saxpy_f32(2.0f, xf, yf, N);
    for (int i = 0; i < N; i++) if (fabsf(yf[i] - 5.0f) > 1e-4f) { fprintf(stderr, "selftest[%s] saxpy_f32 wrong at %d: %g\n", acs_variant_name(), i, (double)yf[i]); fails++; break; }

    /* mul: z = x*y with x=2, y=3 -> 6 everywhere */
    for (int i = 0; i < N; i++) { xf[i] = 2.0f; yf[i] = 3.0f; }
    mul_f32(xf, yf, zf, N);
    for (int i = 0; i < N; i++) if (fabsf(zf[i] - 6.0f) > 1e-4f) { fprintf(stderr, "selftest[%s] mul_f32 wrong at %d\n", acs_variant_name(), i); fails++; break; }

    /* stencil a=b=c=1 on x=1 -> interior == 3 */
    for (int i = 0; i < N; i++) xf[i] = 1.0f;
    stencil_f32(1.0f, 1.0f, 1.0f, xf, yf, N);
    for (int i = 1; i + 1 < N; i++) if (fabsf(yf[i] - 3.0f) > 1e-4f) { fprintf(stderr, "selftest[%s] stencil_f32 wrong at %d\n", acs_variant_name(), i); fails++; break; }

    /* explicit AVX2 gather (native only): reversed permutation, y = 2*1 + 3 = 5 */
    if (acs_have_gather_avx2()) {
        int32_t id[N];
        for (int i = 0; i < N; i++) { id[i] = N - 1 - i; xf[i] = 1.0f; yf[i] = 3.0f; }
        saxpy_f32_gather_avx2(2.0f, xf, yf, id, N);
        for (int i = 0; i < N; i++) if (fabsf(yf[i] - 5.0f) > 1e-4f) { fprintf(stderr, "selftest[%s] saxpy_f32_gather_avx2 wrong at %d\n", acs_variant_name(), i); fails++; break; }
    }

    if (!fails) printf("selftest[%s]: all known-answer checks PASS\n", acs_variant_name());
    return fails;
}

int main(int argc, char **argv) {
    config_t c = {
        .kernel = "saxpy", .dtype = DT_F32, .access = ACC_UNIT,
        .n = 1 << 16, .stride = 1, .offset = 0, .reps = 10, .min_ms = 20.0,
        .warmup = 3, .cpu = -1, .seed = 12345u, .do_check = 1,
        .experiment = "adhoc", .counters = 0,
    };
    int want_header = 0, want_info = 0, want_selftest = 0, want_probe = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define NEXT (argv[++i])
        if (!strcmp(a, "--kernel")) c.kernel = NEXT;
        else if (!strcmp(a, "--dtype")) { const char *v = NEXT; c.dtype = !strcmp(v, "f64") ? DT_F64 : !strcmp(v, "i32") ? DT_I32 : DT_F32; }
        else if (!strcmp(a, "--access")) { const char *v = NEXT; c.access = !strcmp(v, "stride") ? ACC_STRIDE : !strcmp(v, "gather") ? ACC_GATHER : !strcmp(v, "gather_avx2") ? ACC_GATHER_AVX2 : ACC_UNIT; }
        else if (!strcmp(a, "--n")) c.n = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--stride")) c.stride = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--offset")) c.offset = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--reps")) c.reps = atoi(NEXT);
        else if (!strcmp(a, "--min-ms")) c.min_ms = atof(NEXT);
        else if (!strcmp(a, "--warmup")) c.warmup = atoi(NEXT);
        else if (!strcmp(a, "--cpu")) c.cpu = atoi(NEXT);
        else if (!strcmp(a, "--seed")) c.seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--experiment")) c.experiment = NEXT;
        else if (!strcmp(a, "--no-check")) c.do_check = 0;
        else if (!strcmp(a, "--header")) want_header = 1;
        else if (!strcmp(a, "--info")) want_info = 1;
        else if (!strcmp(a, "--selftest")) want_selftest = 1;
        else if (!strcmp(a, "--counters")) c.counters = 1;
        else if (!strcmp(a, "--counters-probe")) want_probe = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }

    if (want_info) {
        acs_perf p;
        int nctr = acs_perf_open(&p);
        acs_perf_close(&p);
        printf("variant=%s\nflags=%s\ntimer_res_ns=%.1f\ngather_avx2=%s\nperf_counters=%d/%d\n",
               acs_variant_name(), acs_variant_flags(),
               acs_timer_resolution_sec() * 1e9,
               acs_have_gather_avx2() ? "yes" : "no", nctr, PC_N);
        return 0;
    }

    /* Exit 0 iff the cycle counter (at least) can be opened. */
    if (want_probe) {
        acs_perf p;
        acs_perf_open(&p);
        int ok = p.fd[PC_CYCLES] >= 0;
        for (int i = 0; i < PC_N; i++)
            printf("%s=%s\n", acs_perf_name(i), p.fd[i] >= 0 ? "ok" : "unavailable");
        acs_perf_close(&p);
        return ok ? 0 : 1;
    }

    if (want_selftest)
        return selftest() ? 1 : 0;

    if (c.stride == 0) c.stride = 1;
    if (c.access == ACC_STRIDE) { c.dtype = DT_F32; c.kernel = "saxpy"; }
    if (is_gather(c.access)) { c.dtype = DT_F32; c.kernel = "saxpy"; c.stride = 1; }
    if (c.access == ACC_GATHER_AVX2 && !acs_have_gather_avx2()) {
        fprintf(stderr, "--access gather_avx2 needs the AVX2+FMA build (variant native), not %s\n",
                acs_variant_name());
        return 2;
    }

    if (c.cpu >= 0 && acs_pin_cpu(c.cpu) != 0)
        fprintf(stderr, "warning: could not pin to CPU %d\n", c.cpu);

    data_t d = alloc_data(&c);
    if (getenv("ACS_DEBUG_ADDR")) /* diagnostics only: array placement (4K-aliasing checks) */
        fprintf(stderr, "x=%p y=%p (y-x) mod 4096 = %ld\n", d.x.ptr, d.y.ptr,
                (long)(((uintptr_t)d.y.ptr - (uintptr_t)d.x.ptr) & 4095u));

    if (c.do_check) {
        double err = 0.0;
        if (!validate(&c, &d, &err)) {
            fprintf(stderr,
                    "VALIDATION FAILED: %s %s n=%zu access=%s stride=%zu offset=%zu variant=%s max_err=%.3e\n",
                    c.kernel, dtype_name(c.dtype), c.n, access_name(c.access),
                    c.stride, c.offset, acs_variant_name(), err);
            free_data(&d);
            return 1;
        }
        if (getenv("ACS_REPORT_ERR")) /* make test: log the error of every passing case */
            fprintf(stderr, "validate-err,%s,%s,%s,%zu,%s,%zu,%zu,%.3e\n", acs_variant_name(),
                    c.kernel, dtype_name(c.dtype), c.n, access_name(c.access), c.stride,
                    c.offset, err);
    }

    reset_y(&c, &d);
    for (int w = 0; w < c.warmup; w++)
        acs_consume_f64(run_kernel(&c, &d));

    size_t iters = calibrate_iters(&c, &d, c.min_ms / 1000.0);

    if (want_header) {
        printf("experiment,kernel,variant,dtype,n,offset,stride,access,flops_per_elem,"
               "rep,iters,time_s,elems_per_s,ns_per_elem,gflops,checksum");
        if (c.counters)
            printf(",cycles,instructions,llc_misses,l1d_misses,cycles_per_elem,"
                   "llc_miss_per_elem,l1d_miss_per_elem,ipc,ghz");
        printf("\n");
    }

    acs_perf perf;
    if (c.counters && acs_perf_open(&perf) == 0)
        fprintf(stderr, "warning: --counters: no hardware counter could be opened; columns are NA\n");

    double fpe = flops_per_elem(c.kernel);
    for (int r = 0; r < c.reps; r++) {
        double sink = 0.0;
        double ctr[PC_N];
        if (c.counters) acs_perf_start(&perf);
        double t0 = acs_now_sec();
        for (size_t k = 0; k < iters; k++)
            sink += run_kernel(&c, &d);
        double dt = acs_now_sec() - t0;
        if (c.counters) acs_perf_stop(&perf, ctr);
        acs_consume_f64(sink);
        double per_call = dt / (double)iters;
        double eps = (double)c.n / per_call;
        double nspe = per_call * 1e9 / (double)c.n;
        double gflops = fpe * (double)c.n / per_call / 1e9;
        double checksum;
        if (c.dtype == DT_F64) checksum = acs_checksum_f64(d.y.ptr, c.n);
        else if (c.dtype == DT_F32) checksum = acs_checksum_f32(d.y.ptr, c.n);
        else checksum = (double)((int32_t *)(d.z.base ? d.z.ptr : d.y.ptr))[0];

        printf("%s,%s,%s,%s,%zu,%zu,%zu,%s,%.1f,%d,%zu,%.9e,%.6e,%.6e,%.6e,%.6e",
               c.experiment, c.kernel, acs_variant_name(), dtype_name(c.dtype),
               c.n, c.offset, c.stride, access_name(c.access), fpe,
               r, iters, per_call, eps, nspe, gflops, checksum);
        if (c.counters) {
            double elems = (double)iters * (double)c.n;
            for (int i = 0; i < PC_N; i++)
                print_na(ctr[i], "%.0f");
            print_na(ctr[PC_CYCLES] / elems, "%.6e");
            print_na(ctr[PC_LLC_MISS] / elems, "%.6e");
            print_na(ctr[PC_L1D_MISS] / elems, "%.6e");
            print_na(ctr[PC_INSNS] / ctr[PC_CYCLES], "%.4f");
            print_na(ctr[PC_CYCLES] / dt / 1e9, "%.4f");
        }
        printf("\n");
    }

    if (c.counters) acs_perf_close(&perf);
    free_data(&d);
    return 0;
}
