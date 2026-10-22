/*
 * kernels.c — kernels under test (Project 1).
 *
 * Compiled once per build variant (see Makefile): the variant's flags decide
 * whether these loops vectorize and at what width. The loops are written in the
 * simplest form that lets the compiler vectorize them (unit-stride, no aliasing
 * surprises, reductions written as a running sum) so that the *flags*, not the
 * source, are what differs between variants. scripts/verify_vectorization.sh
 * confirms which loops actually vectorized.
 */
#include "kernels.h"

#if defined(__AVX2__) && defined(__FMA__)
#include <immintrin.h>
#endif

#ifndef ACS_VARIANT
#define ACS_VARIANT "unknown"
#endif
#ifndef ACS_VARIANT_FLAGS
#define ACS_VARIANT_FLAGS "unknown"
#endif

const char *acs_variant_name(void) { return ACS_VARIANT; }
const char *acs_variant_flags(void) { return ACS_VARIANT_FLAGS; }

/* ----------------------------------------------------- float32 */
void saxpy_f32(float a, const float *x, float *y, size_t n) {
    for (size_t i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}

float dot_f32(const float *x, const float *y, size_t n) {
    float s = 0.0f;
    for (size_t i = 0; i < n; i++)
        s += x[i] * y[i];
    return s;
}

void mul_f32(const float *x, const float *y, float *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

void stencil_f32(float a, float b, float c, const float *x, float *y, size_t n) {
    if (n < 2)
        return;
    y[0] = x[0];
    for (size_t i = 1; i + 1 < n; i++)
        y[i] = a * x[i - 1] + b * x[i] + c * x[i + 1];
    y[n - 1] = x[n - 1];
}

/* ----------------------------------------------------- float64 */
void saxpy_f64(double a, const double *x, double *y, size_t n) {
    for (size_t i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}

double dot_f64(const double *x, const double *y, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; i++)
        s += x[i] * y[i];
    return s;
}

void mul_f64(const double *x, const double *y, double *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

void stencil_f64(double a, double b, double c, const double *x, double *y, size_t n) {
    if (n < 2)
        return;
    y[0] = x[0];
    for (size_t i = 1; i + 1 < n; i++)
        y[i] = a * x[i - 1] + b * x[i] + c * x[i + 1];
    y[n - 1] = x[n - 1];
}

/* ----------------------------------------------------- int32 */
void mul_i32(const int32_t *x, const int32_t *y, int32_t *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

/* ----------------------------------------------------- access-pattern SAXPY */
void saxpy_f32_stride(float a, const float *x, float *y, size_t n, size_t s) {
    for (size_t i = 0; i < n; i++)
        y[i * s] = a * x[i * s] + y[i * s];
}

void saxpy_f32_gather(float a, const float *x, float *y, const int32_t *idx, size_t n) {
    for (size_t i = 0; i < n; i++) {
        size_t j = (size_t)idx[i];
        y[j] = a * x[j] + y[j];
    }
}

/* Explicit AVX2 gather (see kernels.h). GCC does not emit vgatherdps for the
 * loop above on its own (verify_vectorization.sh), so this is the only place a
 * hardware SIMD gather is measured. */
#if defined(__AVX2__) && defined(__FMA__)
int acs_have_gather_avx2(void) { return 1; }

void saxpy_f32_gather_avx2(float a, const float *x, float *y, const int32_t *idx, size_t n) {
    const __m256 va = _mm256_set1_ps(a);
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        __m256i vi = _mm256_loadu_si256((const __m256i *)(idx + i));
        __m256 vx = _mm256_i32gather_ps(x, vi, 4);
        __m256 vy = _mm256_i32gather_ps(y, vi, 4);
        __m256 r = _mm256_fmadd_ps(va, vx, vy);
        float out[8] __attribute__((aligned(32)));
        _mm256_store_ps(out, r);
        for (int k = 0; k < 8; k++) /* no AVX2 scatter: per-lane stores */
            y[idx[i + k]] = out[k];
    }
    for (; i < n; i++) {
        size_t j = (size_t)idx[i];
        y[j] = a * x[j] + y[j];
    }
}
#else
int acs_have_gather_avx2(void) { return 0; }

void saxpy_f32_gather_avx2(float a, const float *x, float *y, const int32_t *idx, size_t n) {
    saxpy_f32_gather(a, x, y, idx, n);
}
#endif
