/*
 * blkbench.c — direct-I/O storage benchmark (Project 3).
 *
 * The project spec recommends FIO. FIO was not installed on the test host when
 * the study was built, so this is a small, auditable benchmark built on Linux
 * libaio (the same async engine FIO's `--ioengine=libaio` uses). It keeps `--qd`
 * requests outstanding against an O_DIRECT file and measures throughput and the
 * full per-I/O latency distribution (submit -> completion; mean, p50/p95/p99/
 * p99.9). When FIO is present, `scripts/run.sh fio_check` runs the same points
 * through FIO (fio/job.fio) and compares the two engines.
 *
 * SAFETY: operates only on a regular file given by --file. The path is lstat()ed
 * BEFORE it is opened, and anything that is not a regular file (block/char
 * device, directory, FIFO, symlink as the last component) is refused without
 * being opened; O_NOFOLLOW closes the stat/open race for symlinks.
 * scripts/safety.sh gates the target before every run, and scripts/run.sh only
 * ever points --file at a disposable file inside the scratch directory
 * (data/scratch/ by default, or $ACS_SCRATCH on another device).
 * All I/O is O_DIRECT with 4 KiB-aligned buffers and block-aligned offsets.
 *
 * DATA PATTERN: every write buffer is filled ONCE, before timing, with an
 * incompressible pseudo-random pattern (xorshift64*, seeded from --seed), each
 * queue slot with different bytes; the preconditioning pass uses the same
 * generator. `--fill zero` selects an all-zero (maximally compressible) pattern
 * for an optional compressibility check; every committed run uses `rand`.
 * In mixed workloads a read overwrites its slot's buffer with file contents,
 * which were themselves written from this generator, so writes stay
 * incompressible.
 *
 * Modes
 *   (default)       --reps repetitions of --runtime seconds; one CSV row per rep:
 *                   experiment,mode,pattern,bs,qd,rwmix,rep,ios,secs,iops,mibps,
 *                   lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,temp_c
 *   --interval S    time series: one row every S seconds of a single run
 *                   (sustained-write / SLC-cache experiment):
 *                   experiment,phase,mode,pattern,bs,qd,rwmix,t_s,gib_done,ios,iops,
 *                   mibps,lat_mean_us,lat_p50_us,lat_p99_us,lat_p999_us,lat_max_us,temp_c
 *   --precondition  exactly one sequential write pass over the whole file (creating
 *                   and fallocate()-ing it first when --size is given); combine with
 *                   --interval to log the pass as a time series.
 *   --buffered      page-cache pitfall demo (no O_DIRECT, synchronous pread/pwrite)
 *
 * Options
 *   --file PATH     disposable target file
 *   --size BYTES    (with --precondition) create/resize the file to this size
 *   --bs BYTES      block size (multiple of 4096)
 *   --span BYTES    restrict the active LBA range to the first BYTES of the file
 *   --qd N          outstanding async requests (queue depth, 1..1024)
 *   --pattern rand|seq
 *   --rwmix R       reads per 10 I/Os (10=100% read, 7=70/30, 5=50/50, 0=100% write)
 *   --runtime SEC   wall-clock budget per repetition (or for the whole --interval run)
 *   --max-bytes N   also stop a repetition once N bytes have been submitted
 *   --temp PATH     sysfs temperature file in millidegrees C (e.g. the NVMe hwmon
 *                   temp1_input); sampled at the end of each rep / interval; -1 if absent
 *   --phase NAME    label for --interval rows
 *   --fill rand|zero, --reps N, --seed S, --experiment NAME, --header
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

typedef struct { struct iocb cb; void *buf; double t_submit; } slot_t;

/* ------------------------------------------------------------------ helpers */
static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static double pct(const double *v, size_t n, double p) {
    if (!n) return 0;
    if (n == 1) return v[0];
    double idx = p * (double)(n - 1); size_t lo = (size_t)idx; double f = idx - (double)lo;
    if (lo + 1 >= n) return v[n - 1];
    return v[lo] + f * (v[lo + 1] - v[lo]);
}

/* Growable latency sample: no silent truncation at high IOPS or long runs. */
typedef struct { double *v; size_t n, cap; } samples_t;
static void s_push(samples_t *s, double x) {
    if (s->n == s->cap) {
        s->cap = s->cap ? s->cap * 2 : (1u << 16);
        double *nv = realloc(s->v, s->cap * sizeof(double));
        if (!nv) { fprintf(stderr, "blkbench: oom (latency samples)\n"); exit(1); }
        s->v = nv;
    }
    s->v[s->n++] = x;
}

/* splitmix64 for offsets (64-bit, so random offsets stay uniform on large files);
 * xorshift64* for the data pattern. */
static uint64_t splitmix64(uint64_t *x) {
    uint64_t z = (*x += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static void fill_buf(void *buf, size_t len, uint64_t seed, int zero) {
    if (zero) { memset(buf, 0, len); return; }
    uint64_t x = splitmix64(&seed) | 1;
    uint64_t *p = buf;
    for (size_t i = 0; i < len / 8; i++) {
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        p[i] = x * 0x2545F4914F6CDD1Dull;
    }
}

static double read_temp_c(const char *path) {
    if (!path) return -1;
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long mdeg = 0;
    int ok = fscanf(f, "%ld", &mdeg) == 1;
    fclose(f);
    return ok ? (double)mdeg / 1000.0 : -1;
}

static void print_interval(const char *experiment, const char *phase, const char *mode,
                           int pattern_rand, size_t bs, int qd, int rwmix, double t_s,
                           unsigned long long done_bytes, size_t ios, double dt,
                           samples_t *lat, double lat_max, const char *temp_path) {
    qsort(lat->v, lat->n, sizeof(double), cmp_d);
    double sum = 0; for (size_t i = 0; i < lat->n; i++) sum += lat->v[i];
    if (dt <= 0) dt = 1e-9;
    double iops = (double)ios / dt;
    printf("%s,%s,%s,%s,%zu,%d,%d,%.3f,%.4f,%zu,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f\n",
           experiment, phase, mode, pattern_rand ? "rand" : "seq", bs, qd, rwmix, t_s,
           (double)done_bytes / (1024.0 * 1024.0 * 1024.0), ios, iops,
           iops * (double)bs / (1024.0 * 1024.0), lat->n ? sum / (double)lat->n : 0.0,
           pct(lat->v, lat->n, 0.50), pct(lat->v, lat->n, 0.99), pct(lat->v, lat->n, 0.999),
           lat_max, read_temp_c(temp_path));
    fflush(stdout);
}

/* ------------------------------------------------------------------ main */
int main(int argc, char **argv) {
    const char *path = NULL, *experiment = NULL, *temp_path = NULL, *phase = "run";
    size_t bs = 4096, span = 0, create_size = 0;
    unsigned long long max_bytes = 0;
    int qd = 1, reps = 3, rwmix = 10, pattern_rand = 1, fill_zero = 0, runtime_set = 0;
    double runtime = 4.0, interval = 0;
    unsigned long long seed = 2026u;
    int want_header = 0, precondition = 0, buffered = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        int flag = !strcmp(a, "--header") || !strcmp(a, "--precondition") || !strcmp(a, "--buffered");
        if (!flag && i + 1 >= argc) { fprintf(stderr, "blkbench: option %s needs a value\n", a); return 2; }
#define NEXT (argv[++i])
        if      (!strcmp(a, "--file"))      path = NEXT;
        else if (!strcmp(a, "--size"))      create_size = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--bs"))        bs = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--span"))      span = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--qd"))        qd = atoi(NEXT);
        else if (!strcmp(a, "--pattern"))   pattern_rand = strcmp(NEXT, "seq") != 0;
        else if (!strcmp(a, "--rwmix"))     rwmix = atoi(NEXT);
        else if (!strcmp(a, "--runtime"))   { runtime = atof(NEXT); runtime_set = 1; }
        else if (!strcmp(a, "--max-bytes")) max_bytes = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--interval"))  interval = atof(NEXT);
        else if (!strcmp(a, "--temp"))      temp_path = NEXT;
        else if (!strcmp(a, "--phase"))     phase = NEXT;
        else if (!strcmp(a, "--fill"))      fill_zero = !strcmp(NEXT, "zero");
        else if (!strcmp(a, "--reps"))      reps = atoi(NEXT);
        else if (!strcmp(a, "--seed"))      seed = strtoull(NEXT, 0, 0);
        else if (!strcmp(a, "--experiment")) experiment = NEXT;
        else if (!strcmp(a, "--precondition")) precondition = 1;
        else if (!strcmp(a, "--buffered"))  buffered = 1; /* page-cache pitfall demo */
        else if (!strcmp(a, "--header"))    want_header = 1;
        else { fprintf(stderr, "unknown option: %s\n", a); return 2; }
#undef NEXT
    }
    if (!experiment) experiment = precondition ? "precondition" : "ssd";
    if (!path) { fprintf(stderr, "blkbench: --file is required\n"); return 2; }
    if (bs == 0 || bs % 4096) { fprintf(stderr, "blkbench: --bs must be a positive multiple of 4096 for O_DIRECT\n"); return 2; }
    if (qd < 1) qd = 1;
    if (qd > 1024) { fprintf(stderr, "blkbench: --qd must be <= 1024\n"); return 2; }
    if (create_size % bs) { fprintf(stderr, "blkbench: --size must be a multiple of --bs\n"); return 2; }
    if (precondition && buffered) { fprintf(stderr, "blkbench: --precondition is O_DIRECT only\n"); return 2; }

    /* ---- safety: inspect the path BEFORE opening it ---- */
    struct stat st;
    int exists = lstat(path, &st) == 0;
    if (exists && !S_ISREG(st.st_mode)) {
        fprintf(stderr, "blkbench: refusing %s: not a regular file (device/dir/fifo/symlink)\n", path);
        return 1;
    }
    if (!exists && !(precondition && create_size)) {
        fprintf(stderr, "blkbench: %s does not exist (create it with --precondition --size)\n", path);
        return 1;
    }
    int oflags = O_RDWR | O_NOFOLLOW | (buffered ? 0 : O_DIRECT) | (exists ? 0 : (O_CREAT | O_EXCL));
    int fd = open(path, oflags, 0644);
    if (fd < 0) { perror("blkbench: open"); return 1; }
    if (fstat(fd, &st) != 0) { perror("fstat"); return 1; }
    if (!S_ISREG(st.st_mode)) { fprintf(stderr, "blkbench: refusing non-regular file %s\n", path); return 1; }

    if (precondition && create_size && (size_t)st.st_size != create_size) {
        /* Allocate the extents up front (unwritten) so the O_DIRECT pass below
         * writes in place instead of extending the file on every request. */
        if (ftruncate(fd, (off_t)create_size) != 0) { perror("ftruncate"); return 1; }
        int e = posix_fallocate(fd, 0, (off_t)create_size);
        if (e) { errno = e; perror("posix_fallocate"); return 1; }
        st.st_size = (off_t)create_size;
    }

    size_t fsize = (size_t)st.st_size;
    if (span > 0 && span < fsize) fsize = span;   /* restrict the active LBA range */
    size_t nblocks = fsize / bs;
    if (nblocks < 16) { fprintf(stderr, "blkbench: file too small (%zu blocks of %zu)\n", nblocks, bs); return 1; }

    /* Preconditioning = exactly one sequential write pass over every block.
     * Without it, O_DIRECT reads of unwritten ext4 extents return zeros without
     * touching the device and report fictitious latency/throughput. */
    if (precondition) {
        pattern_rand = 0; rwmix = 0; reps = 1;
        max_bytes = (unsigned long long)nblocks * bs;
        if (!runtime_set) runtime = 1e9;      /* bounded by bytes unless a time cap is given */
    }

    if (interval > 0) reps = 1;               /* a time series is one continuous run */
    const char *mode = rwmix >= 10 ? "read" : rwmix <= 0 ? "write" : "rw";

    if (want_header) {
        if (interval > 0)
            printf("experiment,phase,mode,pattern,bs,qd,rwmix,t_s,gib_done,ios,iops,mibps,"
                   "lat_mean_us,lat_p50_us,lat_p99_us,lat_p999_us,lat_max_us,temp_c\n");
        else if (!precondition)
            printf("experiment,mode,pattern,bs,qd,rwmix,rep,ios,secs,iops,mibps,"
                   "lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,temp_c\n");
    }

    /* ---- buffered path (page-cache pitfall demo): synchronous, no O_DIRECT ---- */
    if (buffered) {
        void *buf; if (posix_memalign(&buf, 4096, bs)) { fprintf(stderr, "oom\n"); return 1; }
        fill_buf(buf, bs, seed, fill_zero);
        for (int r = 0; r < reps; r++) {
            samples_t lat = {0};
            uint64_t rng = seed + (uint64_t)r * 0x9E3779B97F4A7C15ull;
            size_t seq_blk = 0, rw_counter = 0, ios = 0;
            double t0 = acs_now_sec(), deadline = t0 + runtime;
            while (acs_now_sec() < deadline) {
                size_t blk = pattern_rand ? (size_t)(splitmix64(&rng) % nblocks) : (seq_blk++ % nblocks);
                off_t off = (off_t)blk * (off_t)bs;
                int is_read = ((rw_counter++ % 10) < (size_t)rwmix);
                double s = acs_now_sec();
                ssize_t got = is_read ? pread(fd, buf, bs, off) : pwrite(fd, buf, bs, off);
                double us = (acs_now_sec() - s) * 1e6;
                if (got != (ssize_t)bs) { perror("buffered io"); return 1; }
                s_push(&lat, us);
                ios++;
            }
            double secs = acs_now_sec() - t0;
            qsort(lat.v, lat.n, sizeof(double), cmp_d);
            double sum = 0; for (size_t i = 0; i < lat.n; i++) sum += lat.v[i];
            double iops = (double)ios / secs, mibps = iops * (double)bs / (1024.0*1024.0);
            printf("%s,%s-buffered,%s,%zu,%d,%d,%d,%zu,%.6f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f\n",
                   experiment, mode, pattern_rand ? "rand" : "seq", bs, qd, rwmix, r, ios, secs,
                   iops, mibps, lat.n ? sum/(double)lat.n : 0.0, pct(lat.v,lat.n,0.50),
                   pct(lat.v,lat.n,0.95), pct(lat.v,lat.n,0.99), pct(lat.v,lat.n,0.999),
                   read_temp_c(temp_path));
            free(lat.v);
        }
        free(buf); close(fd); return 0;
    }

    /* ---- O_DIRECT libaio path ---- */
    slot_t *slots = calloc((size_t)qd, sizeof *slots);
    for (int s = 0; s < qd; s++) {
        if (posix_memalign(&slots[s].buf, 4096, bs)) { fprintf(stderr, "oom buf\n"); return 1; }
        fill_buf(slots[s].buf, bs, seed + 1000003ull * (uint64_t)(s + 1), fill_zero);
    }
    struct io_event *evs = calloc((size_t)qd, sizeof *evs);

    for (int r = 0; r < reps; r++) {
        io_context_t ctx = 0;
        int rc = io_setup(qd, &ctx);
        if (rc != 0) { errno = -rc; perror("io_setup"); return 1; }

        samples_t lat = {0};
        uint64_t rng = seed + (uint64_t)r * 0x9E3779B97F4A7C15ull;
        size_t seq_blk = 0, rw_counter = 0, ios = 0, tick_ios = 0;
        unsigned long long submitted = 0, done_bytes = 0;
        int inflight = 0;
        double t_start = acs_now_sec(), deadline = t_start + runtime;
        double next_tick = t_start + interval, tick_start = t_start, lat_max = 0;

        #define CAN_ISSUE() ((max_bytes == 0 || submitted < max_bytes) && \
                             !(precondition && seq_blk >= nblocks))
        #define PREP_AND_SUBMIT(S) do {                                                   \
            size_t blk = pattern_rand ? (size_t)(splitmix64(&rng) % nblocks)              \
                                      : (seq_blk++ % nblocks);                            \
            long long off = (long long)blk * (long long)bs;                               \
            int is_read = ((rw_counter++ % 10) < (size_t)rwmix);                          \
            if (is_read) io_prep_pread(&slots[S].cb, fd, slots[S].buf, bs, off);          \
            else         io_prep_pwrite(&slots[S].cb, fd, slots[S].buf, bs, off);         \
            slots[S].cb.data = (void *)(intptr_t)(S);                                     \
            slots[S].t_submit = acs_now_sec();                                            \
            struct iocb *p = &slots[S].cb;                                                \
            int sr = io_submit(ctx, 1, &p);                                               \
            if (sr != 1) { errno = sr < 0 ? -sr : EIO; perror("io_submit"); return 1; }   \
            submitted += bs; inflight++;                                                  \
        } while (0)

        for (int s = 0; s < qd && CAN_ISSUE(); s++) PREP_AND_SUBMIT(s);

        while (inflight > 0) {
            int got = io_getevents(ctx, 1, qd, evs, NULL);
            if (got < 0) { if (got == -EINTR) continue; errno = -got; perror("io_getevents"); return 1; }
            double now = acs_now_sec();
            /* close any finished intervals (a stall > interval emits empty rows) */
            while (interval > 0 && now >= next_tick) {
                print_interval(experiment, phase, mode, pattern_rand, bs, qd, rwmix,
                               next_tick - t_start, done_bytes, tick_ios,
                               next_tick - tick_start, &lat, lat_max, temp_path);
                lat.n = 0; tick_ios = 0; lat_max = 0;
                tick_start = next_tick; next_tick += interval;
            }
            for (int e = 0; e < got; e++) {
                int s = (int)(intptr_t)evs[e].data;
                if ((long)evs[e].res < 0) { errno = -(long)evs[e].res; perror("io error"); return 1; }
                if ((size_t)evs[e].res != bs) { fprintf(stderr, "blkbench: short I/O (%ld)\n", (long)evs[e].res); return 1; }
                double us = (now - slots[s].t_submit) * 1e6;
                s_push(&lat, us);
                if (us > lat_max) lat_max = us;
                ios++; tick_ios++; done_bytes += bs; inflight--;
                if (now < deadline && CAN_ISSUE()) PREP_AND_SUBMIT(s);
            }
        }
        double secs = acs_now_sec() - t_start;
        #undef PREP_AND_SUBMIT
        #undef CAN_ISSUE

        if (interval > 0) {
            if (tick_ios > 0)   /* final partial interval */
                print_interval(experiment, phase, mode, pattern_rand, bs, qd, rwmix, secs,
                               done_bytes, tick_ios, (t_start + secs) - tick_start,
                               &lat, lat_max, temp_path);
        } else if (!precondition) {
            qsort(lat.v, lat.n, sizeof(double), cmp_d);
            double sum = 0; for (size_t i = 0; i < lat.n; i++) sum += lat.v[i];
            double iops = (double)ios / secs;
            double mibps = iops * (double)bs / (1024.0 * 1024.0);
            printf("%s,%s,%s,%zu,%d,%d,%d,%zu,%.6f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f\n",
                   experiment, mode, pattern_rand ? "rand" : "seq", bs, qd, rwmix, r,
                   ios, secs, iops, mibps, lat.n ? sum / (double)lat.n : 0.0,
                   pct(lat.v, lat.n, 0.50), pct(lat.v, lat.n, 0.95),
                   pct(lat.v, lat.n, 0.99), pct(lat.v, lat.n, 0.999), read_temp_c(temp_path));
            fflush(stdout);
        }
        if (precondition) {
            if (fdatasync(fd) != 0) { perror("fdatasync"); return 1; }
            fprintf(stderr, "precondition: wrote %zu x %zu B (%.1f MiB, %s fill) in %.1fs (%.0f MiB/s)\n",
                    ios, bs, (double)done_bytes / (1024.0*1024.0), fill_zero ? "zero" : "random",
                    secs, (double)done_bytes / (1024.0*1024.0) / secs);
        }
        free(lat.v);
        io_destroy(ctx);
    }
    free(evs);
    for (int s = 0; s < qd; s++) free(slots[s].buf);
    free(slots);
    close(fd);
    return 0;
}
