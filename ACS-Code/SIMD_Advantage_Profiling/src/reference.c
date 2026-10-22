/*
 * reference.c — reference implementations for correctness validation (Project 1).
 *
 * Plain scalar loops. Always compiled with vectorization and FP contraction
 * disabled (see Makefile REF_FLAGS) so the reference evaluates each expression
 * in strict left-to-right, non-fused order. Every build variant's kernel output
 * is compared against these before its timings are trusted (scripts/validate.sh).
 */
#include "kernels.h"

void saxpy_f32_ref(float a, const float *x, float *y, size_t n) {
    for (size_t i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}

float dot_f32_ref(const float *x, const float *y, size_t n) {
    float s = 0.0f;
    for (size_t i = 0; i < n; i++)
        s += x[i] * y[i];
    return s;
}

void mul_f32_ref(const float *x, const float *y, float *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

void stencil_f32_ref(float a, float b, float c, const float *x, float *y, size_t n) {
    if (n < 2)
        return;
    y[0] = x[0];
    for (size_t i = 1; i + 1 < n; i++)
        y[i] = a * x[i - 1] + b * x[i] + c * x[i + 1];
    y[n - 1] = x[n - 1];
}

void saxpy_f64_ref(double a, const double *x, double *y, size_t n) {
    for (size_t i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}

double dot_f64_ref(const double *x, const double *y, size_t n) {
    double s = 0.0;
    for (size_t i = 0; i < n; i++)
        s += x[i] * y[i];
    return s;
}

void mul_f64_ref(const double *x, const double *y, double *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

void stencil_f64_ref(double a, double b, double c, const double *x, double *y, size_t n) {
    if (n < 2)
        return;
    y[0] = x[0];
    for (size_t i = 1; i + 1 < n; i++)
        y[i] = a * x[i - 1] + b * x[i] + c * x[i + 1];
    y[n - 1] = x[n - 1];
}

void mul_i32_ref(const int32_t *x, const int32_t *y, int32_t *z, size_t n) {
    for (size_t i = 0; i < n; i++)
        z[i] = x[i] * y[i];
}

void saxpy_f32_stride_ref(float a, const float *x, float *y, size_t n, size_t s) {
    for (size_t i = 0; i < n; i++)
        y[i * s] = a * x[i * s] + y[i * s];
}

void saxpy_f32_gather_ref(float a, const float *x, float *y, const int32_t *idx, size_t n) {
    for (size_t i = 0; i < n; i++) {
        size_t j = (size_t)idx[i];
        y[j] = a * x[j] + y[j];
    }
}
