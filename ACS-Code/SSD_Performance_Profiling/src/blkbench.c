/*
 * blkbench.c — direct-I/O storage benchmark (Project 3).
 *
 * The project spec recommends FIO. FIO is NOT installed on the test host (and we
 * cannot install it), so this is a small, honest stand-in built on Linux libaio
 * (the same async engine FIO's `--ioengine=libaio` uses). It keeps `--qd`
 * requests outstanding against an O_DIRECT file and measures throughput and the
 * full I/O latency distribution (mean, p50/p95/p99/p99.9), so the required
 * zero-queue, block-size, read/write-mix, queue-depth and tail-latency
 * experiments can all be driven from it.
 *
 * SAFETY: operates only on a regular file given by --file; it never opens a block
 * device or partition. scripts/safety.sh gates the target before any run, and
 * scripts/run.sh only ever points --file at a disposable file inside the scratch
 * directory (data/scratch/ by default, or $ACS_SCRATCH on another device).
 * All I/O is O_DIRECT with block-aligned buffers and offsets (page-cache bypass).
 *
 * DEVICE-UNDER-TEST NOTE: the device measured is whatever filesystem holds the
 * scratch file. The committed numbers were taken against a disposable file on the
 * Micron 2210 NVMe SSD (mounted at /, reached via ACS_SCRATCH=$HOME/acs_ssd_scratch),
 * so QD=1 random-read latency is in the tens of microseconds. The code is
 * device-agnostic: pointing the scratch dir at any other writable filesystem
 * profiles that device instead; the report labels the measured device explicitly.
 *
 *   --file PATH    disposable O_DIRECT target (must already be the right size)
 *   --bs BYTES     block size (must be a multiple of 4096 for O_DIRECT)
 *   --qd N         queue depth: outstanding async requests
 *   --pattern rand|seq
 *   --rwmix R      reads per 10 I/Os (10=100% read, 7=70/30, 5=50/50, 0=100% write)
 *   --runtime SEC  wall-clock budget per repetition
 *   --reps N, --seed S, --experiment NAME, --header
 */
#define _GNU_SOURCE
#include "common.h"

#include <errno.h>
#include <fcntl.h>
#include <libaio.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

typedef struct { struct iocb cb; void *buf; double t_submit; int inflight; } slot_t;

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static double pct(double *v, size_t n, double p) {
    if (!n) return 0;
    if (n == 1) return v[0];
    double idx = p * (double)(n - 1); size_t lo = (size_t)idx; double f = idx - (double)lo;
    if (lo + 1 >= n) return v[n - 1];
    return v[lo] + f * (v[lo + 1] - v[lo]);
}

int main(int argc, char **argv) {
    const char *path = NULL, *experiment = "ssd";
    size_t bs = 4096, span = 0; /* span>0 limits the active LBA range to the first span bytes */
    int qd = 1, reps = 3, rwmix = 10, pattern_rand = 1;
    double runtime = 4.0;
    unsigned seed = 2026u;
    int want_header = 0, precondition = 0, buffered = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define NEXT (argv[++i])
        if      (!strcmp(a, "--file"))    path = NEXT;
        else if (!strcmp(a, "--bs"))      bs = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--span"))    span = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--qd"))      qd = atoi(NEXT);
        else if (!strcmp(a, "--pattern")) pattern_rand = strcmp(NEXT, "seq") != 0;
        else if (!strcmp(a, "--rwmix"))   rwmix = atoi(NEXT);
        else if (!strcmp(a, "--runtime")) runtime = atof(NEXT);
        else if (!strcmp(a, "--reps"))    reps = atoi(NEXT);
        else if (!strcmp(a, "--seed"))    seed = (unsigned)strtoul(NEXT, 0, 0);
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--precondition")) precondition = 1;
        else if (!strcmp(a, "--buffered")) buffered = 1; /* page-cache pitfall demo */
        else if (!strcmp(a, "--header"))  want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (!path) { fprintf(stderr, "blkbench: --file is required\n"); return 2; }
    if (bs % 4096) { fprintf(stderr, "blkbench: --bs must be a multiple of 4096 for O_DIRECT\n"); return 2; }
    if (qd < 1) qd = 1;

    int fd = open(path, O_RDWR | (buffered ? 0 : O_DIRECT));
    if (fd < 0) { perror("blkbench: open"); return 1; }
    struct stat st; if (fstat(fd, &st) != 0) { perror("fstat"); return 1; }
    if (!S_ISREG(st.st_mode)) { fprintf(stderr, "blkbench: refusing non-regular file %s\n", path); return 1; }
    size_t fsize = (size_t)st.st_size;
    if (span > 0 && span < fsize) fsize = span;   /* restrict the active LBA range */
    size_t nblocks = fsize / bs;
    if (nblocks < 16) { fprintf(stderr, "blkbench: file too small (%zu blocks of %zu)\n", nblocks, bs); return 1; }

    /* Preconditioning: write every block of the file once, sequentially, with
     * O_DIRECT so the extents are really allocated and written on the medium.
     * Without this, O_DIRECT reads of unwritten ext4 extents would return without
     * touching the device and report fictitious latency/throughput. */
    if (precondition) {
        void *buf; if (posix_memalign(&buf, 4096, bs)) { fprintf(stderr, "oom\n"); return 1; }
        memset(buf, 0xA5, bs);
        double t0 = acs_now_sec();
        for (size_t blk = 0; blk < nblocks; blk++) {
            ssize_t w = pwrite(fd, buf, bs, (off_t)blk * (off_t)bs);
            if (w != (ssize_t)bs) { perror("precondition pwrite"); return 1; }
        }
        fsync(fd);
        fprintf(stderr, "precondition: wrote %zu blocks x %zu B (%.1f MiB) in %.1fs\n",
                nblocks, bs, (double)fsize / (1024.0*1024.0), acs_now_sec() - t0);
        free(buf); close(fd); return 0;
    }

    if (want_header)
        printf("experiment,mode,pattern,bs,qd,rwmix,rep,ios,secs,iops,mibps,"
               "lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us\n");

    const char *mode = rwmix >= 10 ? "read" : rwmix <= 0 ? "write" : "rw";

    /* Buffered path (page-cache pitfall demo): plain synchronous pread/pwrite, no
     * O_DIRECT, so the OS page cache serves most I/O from RAM. This is the
     * misleading setup; its numbers are not device numbers. */
    if (buffered) {
        void *buf; if (posix_memalign(&buf, 4096, bs)) { fprintf(stderr, "oom\n"); return 1; }
        for (int r = 0; r < reps; r++) {
            size_t lat_cap = 1u << 21, lat_n = 0; double *lat = malloc(lat_cap * sizeof(double));
            unsigned rng = seed + (unsigned)r * 2654435761u; size_t seq_blk = 0, rw_counter = 0, ios = 0;
            double t0 = acs_now_sec(), deadline = t0 + runtime;
            while (acs_now_sec() < deadline) {
                rng = rng * 1664525u + 1013904223u;
                size_t blk = pattern_rand ? (rng % nblocks) : (seq_blk++ % nblocks);
                off_t off = (off_t)blk * (off_t)bs;
                int is_read = ((rw_counter++ % 10) < (size_t)rwmix);
                double s = acs_now_sec();
                ssize_t got = is_read ? pread(fd, buf, bs, off) : pwrite(fd, buf, bs, off);
                double us = (acs_now_sec() - s) * 1e6;
                if (got != (ssize_t)bs) { perror("buffered io"); return 1; }
                if (lat_n < lat_cap) lat[lat_n++] = us;
                ios++;
            }
            double secs = acs_now_sec() - t0;
            qsort(lat, lat_n, sizeof(double), cmp_d);
            double sum = 0; for (size_t i = 0; i < lat_n; i++) sum += lat[i];
            double iops = (double)ios / secs, mibps = iops * (double)bs / (1024.0*1024.0);
            printf("%s,%s-buffered,%s,%zu,%d,%d,%d,%zu,%.6f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                   experiment, mode, pattern_rand ? "rand" : "seq", bs, qd, rwmix, r, ios, secs,
                   iops, mibps, lat_n ? sum/(double)lat_n : 0.0, pct(lat,lat_n,0.50),
                   pct(lat,lat_n,0.95), pct(lat,lat_n,0.99), pct(lat,lat_n,0.999));
            free(lat);
        }
        free(buf); close(fd); return 0;
    }

    for (int r = 0; r < reps; r++) {
        io_context_t ctx = 0;
        if (io_setup(qd, &ctx) != 0) { perror("io_setup"); return 1; }
        slot_t *slots = calloc(qd, sizeof *slots);
        for (int s = 0; s < qd; s++)
            if (posix_memalign(&slots[s].buf, 4096, bs)) { fprintf(stderr, "oom buf\n"); return 1; }

        size_t lat_cap = 1u << 20, lat_n = 0;
        double *lat = malloc(lat_cap * sizeof(double));

        unsigned rng = seed + (unsigned)r * 2654435761u;
        size_t seq_blk = 0, rw_counter = 0, ios = 0;
        double t_start = acs_now_sec(), deadline = t_start + runtime;

        /* choose the next op + offset for a slot, prep its iocb, submit it */
        #define PREP_AND_SUBMIT(S) do {                                            \
            rng = rng * 1664525u + 1013904223u;                                    \
            size_t blk = pattern_rand ? (rng % nblocks) : (seq_blk++ % nblocks);   \
            long long off = (long long)blk * (long long)bs;                        \
            int is_read = ((rw_counter++ % 10) < (size_t)rwmix);                   \
            if (is_read) io_prep_pread(&slots[S].cb, fd, slots[S].buf, bs, off);   \
            else         io_prep_pwrite(&slots[S].cb, fd, slots[S].buf, bs, off);  \
            slots[S].cb.data = (void *)(intptr_t)(S);                              \
            slots[S].t_submit = acs_now_sec();                                     \
            struct iocb *p = &slots[S].cb;                                         \
            if (io_submit(ctx, 1, &p) != 1) { perror("io_submit"); return 1; }     \
            slots[S].inflight = 1;                                                 \
        } while (0)

        for (int s = 0; s < qd; s++) PREP_AND_SUBMIT(s);

        int inflight = qd;
        struct io_event *evs = calloc(qd, sizeof *evs);
        while (inflight > 0) {
            int got = io_getevents(ctx, 1, qd, evs, NULL);
            if (got < 0) { if (got == -EINTR) continue; errno = -got; perror("io_getevents"); return 1; }
            double now = acs_now_sec();
            for (int e = 0; e < got; e++) {
                int s = (int)(intptr_t)evs[e].data;
                if ((long)evs[e].res < 0) { errno = -(long)evs[e].res; perror("io error"); return 1; }
                double us = (now - slots[s].t_submit) * 1e6;
                if (lat_n < lat_cap) lat[lat_n++] = us;
                ios++;
                slots[s].inflight = 0;
                if (now < deadline) PREP_AND_SUBMIT(s);
                else inflight--;
            }
        }
        double secs = acs_now_sec() - t_start;
        #undef PREP_AND_SUBMIT

        qsort(lat, lat_n, sizeof(double), cmp_d);
        double sum = 0; for (size_t i = 0; i < lat_n; i++) sum += lat[i];
        double iops = (double)ios / secs;
        double mibps = iops * (double)bs / (1024.0 * 1024.0);
        printf("%s,%s,%s,%zu,%d,%d,%d,%zu,%.6f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
               experiment, mode, pattern_rand ? "rand" : "seq", bs, qd, rwmix, r,
               ios, secs, iops, mibps, lat_n ? sum / (double)lat_n : 0.0,
               pct(lat, lat_n, 0.50), pct(lat, lat_n, 0.95),
               pct(lat, lat_n, 0.99), pct(lat, lat_n, 0.999));

        free(evs); free(lat);
        for (int s = 0; s < qd; s++) free(slots[s].buf);
        free(slots); io_destroy(ctx);
    }
    close(fd);
    return 0;
}
