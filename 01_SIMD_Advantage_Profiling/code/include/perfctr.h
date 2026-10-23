/*
 * perfctr.h — minimal hardware-counter access via the perf_event_open syscall.
 *
 * No `perf` binary and no root are needed: with perf_event_paranoid <= 2 an
 * unprivileged process may count *user-space* events of its own threads
 * (exclude_kernel = exclude_hv = 1). Every counter is opened independently, so
 * an event the PMU or kernel does not offer simply reads as "not available"
 * (NAN) and the caller prints NA; nothing aborts.
 *
 *   acs_perf p; acs_perf_open(&p);
 *   acs_perf_start(&p);  ... timed work ...  acs_perf_stop(&p, v);   // v[PC_*]
 *   acs_perf_close(&p);
 */
#ifndef ACS_PERFCTR_H
#define ACS_PERFCTR_H

#include <stdint.h>

enum {
    PC_CYCLES = 0,   /* core clock cycles (user)                         */
    PC_INSNS,        /* retired instructions (user)                      */
    PC_LLC_MISS,     /* last-level-cache misses (generic HW cache-miss)  */
    PC_L1D_MISS,     /* L1D read misses (HW cache event)                 */
    PC_N
};

typedef struct {
    int fd[PC_N];    /* -1 when the event could not be opened */
} acs_perf;

/* Open every event; returns the number successfully opened. */
int  acs_perf_open(acs_perf *p);
/* Reset + enable all open counters. */
void acs_perf_start(acs_perf *p);
/* Disable and read; v[i] is the (multiplex-scaled) count or NAN if unavailable. */
void acs_perf_stop(acs_perf *p, double v[PC_N]);
void acs_perf_close(acs_perf *p);
const char *acs_perf_name(int i);

#endif /* ACS_PERFCTR_H */
