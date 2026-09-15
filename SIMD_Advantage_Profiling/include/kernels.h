/*
 * kernels.h — declarations for the kernels under test (Project 1).
 *
 * TODO: declare at least three kernels for each data type studied (float32, float64,
 * optionally int32):
 *   - SAXPY/AXPY             y = a*x + y
 *   - dot product            s = sum(x[i] * y[i])
 *   - elementwise multiply   z[i] = x[i] * y[i]
 *   - 3-point stencil        y[i] = a*x[i-1] + b*x[i] + c*x[i+1]
 * plus the variants needed for the stride / gather study, and matching reference
 * versions (src/reference.c) for validation.
 */
