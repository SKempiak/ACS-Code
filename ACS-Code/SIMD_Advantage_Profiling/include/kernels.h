/*
 * kernels.h — declarations for the kernels under test (Project 1).
 *
 * Four kernels, each in float32 and float64 (plus int32 elementwise multiply
 * for the data-type study):
 *   - SAXPY/AXPY             y[i] = a*x[i] + y[i]
 *   - dot product            s = sum(x[i] * y[i])
 *   - elementwise multiply   z[i] = x[i] * y[i]
 *   - 3-point stencil        y[i] = a*x[i-1] + b*x[i] + c*x[i+1]
 * plus strided and gather SAXPY variants for the access-pattern study.
 *
 * kernels.c is compiled once per build variant (scalar / autovec / native).
 * reference.c provides the *_ref versions, always compiled scalar with FP
 * contraction disabled, for correctness validation.
 */
#ifndef ACS_KERNELS_H
#define ACS_KERNELS_H

#include <stddef.h>
#include <stdint.h>

/* ----------------------------------------------------- float32 kernels */
void  saxpy_f32(float a, const float *x, float *y, size_t n);
float dot_f32(const float *x, const float *y, size_t n);
void  mul_f32(const float *x, const float *y, float *z, size_t n);
void  stencil_f32(float a, float b, float c, const float *x, float *y, size_t n);

/* ----------------------------------------------------- float64 kernels */
void   saxpy_f64(double a, const double *x, double *y, size_t n);
double dot_f64(const double *x, const double *y, size_t n);
void   mul_f64(const double *x, const double *y, double *z, size_t n);
void   stencil_f64(double a, double b, double c, const double *x, double *y, size_t n);

/* ----------------------------------------------------- int32 kernel */
void mul_i32(const int32_t *x, const int32_t *y, int32_t *z, size_t n);

/* ----------------------------------------------------- access-pattern SAXPY (f32) */
/* Process n elements at positions 0, s, 2s, ... (arrays must hold n*s elements). */
void saxpy_f32_stride(float a, const float *x, float *y, size_t n, size_t s);
/* y[idx[i]] = a*x[idx[i]] + y[idx[i]] for i in [0,n). */
void saxpy_f32_gather(float a, const float *x, float *y, const int32_t *idx, size_t n);

/* ----------------------------------------------------- reference versions (reference.c) */
void   saxpy_f32_ref(float a, const float *x, float *y, size_t n);
float  dot_f32_ref(const float *x, const float *y, size_t n);
void   mul_f32_ref(const float *x, const float *y, float *z, size_t n);
void   stencil_f32_ref(float a, float b, float c, const float *x, float *y, size_t n);
void   saxpy_f64_ref(double a, const double *x, double *y, size_t n);
double dot_f64_ref(const double *x, const double *y, size_t n);
void   mul_f64_ref(const double *x, const double *y, double *z, size_t n);
void   stencil_f64_ref(double a, double b, double c, const double *x, double *y, size_t n);
void   mul_i32_ref(const int32_t *x, const int32_t *y, int32_t *z, size_t n);
void   saxpy_f32_stride_ref(float a, const float *x, float *y, size_t n, size_t s);
void   saxpy_f32_gather_ref(float a, const float *x, float *y, const int32_t *idx, size_t n);

/* ----------------------------------------------------- build-variant identity */
/* Defined in kernels.c, which carries the per-variant -DACS_VARIANT* macros. */
const char *acs_variant_name(void);
const char *acs_variant_flags(void);

#endif /* ACS_KERNELS_H */
