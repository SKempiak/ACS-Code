/*
 * clock_check.c — is the core clock fixed, and how much wall time does a pinned thread lose? (P2)
 *
 * Diagnostic written to explain why the in-process add-chain probe (`ghz` column of
 * mem_latency / kernel_miss) read ~2.41 GHz in about a third of runs with turbo off.
 * For each window of --ms milliseconds, spinning on the pinned CPU, it reports
 *   core_ghz   = core cycles / reference cycles * TSC GHz  (the actual clock while running)
 *   user_frac  = reference cycles (scaled for multiplexing) / (wall time * TSC GHz)   (fraction of wall time this thread
 *                spent executing user code; ref cycles stop when the thread is not running)
 *   probe_ghz  = the add-chain probe (mp_measure_ghz), run in alternate windows
 *   gpe        = increase of /sys/firmware/acpi/interrupts/gpe_all during the window
 *   imc_*      = system-wide DRAM read/write GiB/s (uncore IMC): the background traffic of an
 *                otherwise idle machine, subtracted from experiment readings
 * A user_frac well below 1 with core_ghz unchanged means time was taken away from the thread
 * (preemption, interrupts or firmware/SMM time that the OS does not see), not a lower clock.
 *
 *   clock_check --cpu 2 --windows 30 --ms 300
 */
#define _GNU_SOURCE
#include "common.h"
#include "memprof.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long read_gpe(void) {
    FILE *f = fopen("/sys/firmware/acpi/interrupts/gpe_all", "r");
    long v = -1;
    if (f) { if (fscanf(f, "%ld", &v) != 1) v = -1; fclose(f); }
    return v;
}

int main(int argc, char **argv) {
    int cpu = 2, windows = 30;
    double ms = 300.0;
    for (int i = 1; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "--cpu")) cpu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--windows")) windows = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ms")) ms = atof(argv[++i]);
    }
    if (acs_pin_cpu(cpu) != 0) fprintf(stderr, "warning: could not pin to CPU %d\n", cpu);
    double tsc = mp_tsc_ghz();
    int fc = mp_perf_open(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES);
    int fr = mp_perf_open(PERF_TYPE_HARDWARE, PERF_COUNT_HW_REF_CPU_CYCLES);
    if (fc < 0 || fr < 0) { fprintf(stderr, "clock_check: perf_event_open failed\n"); return 1; }
    mp_imc imc;
    mp_imc_open(&imc, 1);
    mp_imc_start(&imc);
    printf("cpu,window,kind,tsc_ghz,wall_s,core_ghz,user_frac,probe_ghz,gpe,imc_rd_gib_s,imc_wr_gib_s\n");
    for (int w = 0; w < windows; w++) {
        int probe = w % 2;   /* odd windows run the add-chain probe instead of a plain spin */
        long g0 = read_gpe();
        double m0[2], m1[2];
        mp_imc_read(&imc, m0);
        ioctl(fc, PERF_EVENT_IOC_RESET, 0); ioctl(fr, PERF_EVENT_IOC_RESET, 0);
        ioctl(fc, PERF_EVENT_IOC_ENABLE, 0); ioctl(fr, PERF_EVENT_IOC_ENABLE, 0);
        double t0 = acs_now_sec(), pg = NAN;
        if (probe) pg = mp_measure_ghz();
        else while (acs_now_sec() - t0 < ms / 1000.0) { }
        double dt = acs_now_sec() - t0;
        ioctl(fc, PERF_EVENT_IOC_DISABLE, 0); ioctl(fr, PERF_EVENT_IOC_DISABLE, 0);
        long g1 = read_gpe();
        mp_imc_read(&imc, m1);
        uint64_t a[3] = {0}, b[3] = {0};
        if (read(fc, a, sizeof a) != (ssize_t)sizeof a || read(fr, b, sizeof b) != (ssize_t)sizeof b) return 1;
        printf("%d,%d,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%ld,%.6e,%.6e\n", cpu, w, probe ? "probe" : "spin", tsc, dt,
               b[0] ? (double)a[0] / (double)b[0] * tsc : NAN,
               /* scale by enabled/running: other users of the PMU may multiplex our events */
               b[2] ? (double)b[0] * ((double)b[1] / (double)b[2]) / (dt * tsc * 1e9) : NAN, pg,
               (g0 >= 0 && g1 >= 0) ? g1 - g0 : -1,
               (m1[0] - m0[0]) / dt / 1073741824.0, (m1[1] - m0[1]) / dt / 1073741824.0);
        fflush(stdout);
    }
    return 0;
}
