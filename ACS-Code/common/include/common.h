/*
 * common.h — helpers shared by more than one project.
 *
 * Provides a monotonic timer, aligned/offset allocation, CPU pinning and a
 * small CSV raw-row writer. Project-specific logic stays in the project
 * directories; only genuinely reusable pieces live here.
 */
#ifndef ACS_COMMON_H
#define ACS_COMMON_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- timing */
/* Seconds from a monotonic raw clock (not affected by NTP/freq scaling of the
 * wall clock). Use differences only; the absolute epoch is unspecified. */
double acs_now_sec(void);

/* Timer resolution in seconds (clock_getres of the same clock). */
double acs_timer_resolution_sec(void);

/* ---------------------------------------------------------------- memory */
/* An allocation whose usable pointer may be deliberately offset from an
 * aligned base. Free with acs_free() using the base. */
typedef struct {
    void  *base; /* what to free */
    void  *ptr;  /* aligned base + offset_bytes; use this in the kernel */
} acs_buf;

/* Allocate `bytes` usable bytes. The base is aligned to `align` (power of two,
 * >= sizeof(void*)); `ptr` is `base + offset_bytes`. The underlying block is
 * sized so that `ptr .. ptr+bytes` is valid. Aborts on failure. */
acs_buf acs_alloc(size_t bytes, size_t align, size_t offset_bytes);
void    acs_free(acs_buf b);

/* ---------------------------------------------------------------- pinning */
/* Pin the calling thread to one logical CPU. Returns 0 on success, -1 on
 * failure (e.g. restricted container); the caller should report, not abort. */
int acs_pin_cpu(int cpu);

/* ---------------------------------------------------------------- output */
/* Prevent the optimizer from treating a computed value as dead. */
void acs_consume_f64(double v);
void acs_consume_f32(float v);
void acs_consume_i64(int64_t v);

/* Running checksum of a float32/float64 array (used both as a validation hook
 * and as a sink so stores are not eliminated). */
double acs_checksum_f32(const float *a, size_t n);
double acs_checksum_f64(const double *a, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* ACS_COMMON_H */
