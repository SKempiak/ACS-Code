/*
 * common.c — implementations for common.h.
 *
 * Compiled with the fixed "harness" flags (never the per-variant kernel flags)
 * so timing and bookkeeping are identical across build variants.
 */
#define _GNU_SOURCE
#include "common.h"

#include <sched.h>
#include <stdlib.h>
#include <time.h>

/* ---------------------------------------------------------------- timing */
#ifndef CLOCK_MONOTONIC_RAW
#define CLOCK_MONOTONIC_RAW CLOCK_MONOTONIC
#endif

double acs_now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

double acs_timer_resolution_sec(void) {
    struct timespec ts;
    if (clock_getres(CLOCK_MONOTONIC_RAW, &ts) != 0)
        return 0.0;
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---------------------------------------------------------------- memory */
acs_buf acs_alloc(size_t bytes, size_t align, size_t offset_bytes) {
    acs_buf b = {0, 0};
    if (align < sizeof(void *))
        align = sizeof(void *);
    /* Over-allocate so base can be aligned and ptr = base + offset is valid. */
    size_t total = bytes + offset_bytes + align;
    void *base = NULL;
    if (posix_memalign(&base, align, total) != 0 || base == NULL) {
        fprintf(stderr, "acs_alloc: out of memory (%zu bytes)\n", total);
        abort();
    }
    b.base = base;
    b.ptr = (void *)((char *)base + offset_bytes);
    return b;
}

void acs_free(acs_buf b) { free(b.base); }

/* ---------------------------------------------------------------- pinning */
int acs_pin_cpu(int cpu) {
    if (cpu < 0)
        return 0; /* no pinning requested */
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0)
        return -1;
    return 0;
}

/* ---------------------------------------------------------------- output */
/* A volatile sink: writing through it forces the preceding computation to be
 * materialised, defeating dead-code elimination of a kernel's result. */
static volatile double g_sink_f64;
static volatile float  g_sink_f32;
static volatile int64_t g_sink_i64;

void acs_consume_f64(double v) { g_sink_f64 = v; }
void acs_consume_f32(float v) { g_sink_f32 = v; }
void acs_consume_i64(int64_t v) { g_sink_i64 = v; }

double acs_checksum_f32(const float *a, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; i++)
        s += (double)a[i];
    return s;
}

double acs_checksum_f64(const double *a, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; i++)
        s += a[i];
    return s;
}
