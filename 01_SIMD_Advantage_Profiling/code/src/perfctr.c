/*
 * perfctr.c — user-space hardware counters through perf_event_open(2).
 * See include/perfctr.h. Linux only; on any failure the counter reads NAN.
 */
#define _GNU_SOURCE
#include "perfctr.h"

#include <math.h>
#include <string.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>

static int open_event(uint32_t type, uint64_t config) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = type;
    a.config = config;
    a.disabled = 1;
    a.exclude_kernel = 1; /* required for perf_event_paranoid = 2 */
    a.exclude_hv = 1;
    a.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
    long fd = syscall(SYS_perf_event_open, &a, 0 /* this thread */, -1 /* any cpu */, -1, 0);
    return (int)fd;
}

int acs_perf_open(acs_perf *p) {
    const uint64_t l1d_read_miss = PERF_COUNT_HW_CACHE_L1D |
                                   (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                                   (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
    p->fd[PC_CYCLES]   = open_event(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES);
    p->fd[PC_INSNS]    = open_event(PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS);
    p->fd[PC_LLC_MISS] = open_event(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES);
    p->fd[PC_L1D_MISS] = open_event(PERF_TYPE_HW_CACHE, l1d_read_miss);
    int ok = 0;
    for (int i = 0; i < PC_N; i++)
        ok += p->fd[i] >= 0;
    return ok;
}

void acs_perf_start(acs_perf *p) {
    for (int i = 0; i < PC_N; i++)
        if (p->fd[i] >= 0) {
            ioctl(p->fd[i], PERF_EVENT_IOC_RESET, 0);
            ioctl(p->fd[i], PERF_EVENT_IOC_ENABLE, 0);
        }
}

void acs_perf_stop(acs_perf *p, double v[PC_N]) {
    for (int i = 0; i < PC_N; i++)
        if (p->fd[i] >= 0)
            ioctl(p->fd[i], PERF_EVENT_IOC_DISABLE, 0);
    for (int i = 0; i < PC_N; i++) {
        v[i] = NAN;
        if (p->fd[i] < 0)
            continue;
        uint64_t buf[3]; /* value, time_enabled, time_running */
        if (read(p->fd[i], buf, sizeof buf) != (ssize_t)sizeof buf || buf[2] == 0)
            continue;
        /* scale if the kernel had to multiplex the PMU */
        v[i] = (double)buf[0] * ((double)buf[1] / (double)buf[2]);
    }
}

void acs_perf_close(acs_perf *p) {
    for (int i = 0; i < PC_N; i++)
        if (p->fd[i] >= 0) {
            close(p->fd[i]);
            p->fd[i] = -1;
        }
}
#else  /* !__linux__ */
int  acs_perf_open(acs_perf *p) { for (int i = 0; i < PC_N; i++) p->fd[i] = -1; return 0; }
void acs_perf_start(acs_perf *p) { (void)p; }
void acs_perf_stop(acs_perf *p, double v[PC_N]) { (void)p; for (int i = 0; i < PC_N; i++) v[i] = NAN; }
void acs_perf_close(acs_perf *p) { (void)p; }
#endif

const char *acs_perf_name(int i) {
    static const char *names[PC_N] = {"cycles", "instructions", "llc_misses", "l1d_misses"};
    return (i >= 0 && i < PC_N) ? names[i] : "?";
}
