/*
 * summarize.c — turn raw measurements into processed data (all projects).
 *
 * Reads a raw CSV (one row per repetition, with a header) and reduces it to one
 * row per configuration group, writing median / q25 / q75 for each requested
 * metric. Optionally adds speedup_vs_scalar (requires `variant` among the group
 * columns and `elems_per_s` among the metrics): for each group it divides that
 * group's median throughput by the throughput of the otherwise-identical
 * variant=scalar group.
 *
 *   summarize --in raw.csv --out out.csv --group n,kernel,variant \
 *             --stat elems_per_s,ns_per_elem [--speedup]
 *
 * The ACS-Latex figures read the output directly with pgfplots, so the column
 * names must stay stable:
 *   <group columns...>, <metric>_median, <metric>_q25, <metric>_q75, speedup_vs_scalar
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_COLS   64
#define MAX_GROUP  16
#define MAX_STAT   8

/* ---------------- CSV helpers ---------------- */
static char *trim(char *s) {
    while (*s == ' ' || *s == '\t') s++;
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' '))
        s[--n] = 0;
    return s;
}

/* Split a mutable CSV line into fields (in place). Returns field count. */
static int split(char *line, char **out, int max) {
    int n = 0;
    char *p = line;
    out[n++] = p;
    while (*p && n < max) {
        if (*p == ',') { *p = 0; out[n++] = p + 1; }
        p++;
    }
    return n;
}

/* ---------------- stats ---------------- */
static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static double percentile(double *v, int n, double p) {
    if (n == 0) return 0.0;
    if (n == 1) return v[0];
    double idx = p * (n - 1);
    int lo = (int)idx;
    double frac = idx - lo;
    if (lo + 1 >= n) return v[n - 1];
    return v[lo] + frac * (v[lo + 1] - v[lo]);
}

/* ---------------- group table ---------------- */
typedef struct {
    char   key[512];                 /* join of group-column values */
    char   gvals[MAX_GROUP][64];     /* group-column values, display order */
    double *vals[MAX_STAT];          /* per-metric raw values */
    int    nvals[MAX_STAT];
    int    cap[MAX_STAT];
    double median[MAX_STAT];
    double q25[MAX_STAT];
    double q75[MAX_STAT];
    int    reps;
    double speedup;
} group_t;

int main(int argc, char **argv) {
    const char *in = NULL, *out = NULL;
    char *group_arg = NULL, *stat_arg = NULL;
    int want_speedup = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--in")) in = argv[++i];
        else if (!strcmp(argv[i], "--out")) out = argv[++i];
        else if (!strcmp(argv[i], "--group")) group_arg = argv[++i];
        else if (!strcmp(argv[i], "--stat")) stat_arg = argv[++i];
        else if (!strcmp(argv[i], "--speedup")) want_speedup = 1;
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }
    if (!in || !out || !group_arg || !stat_arg) {
        fprintf(stderr, "usage: summarize --in f --out f --group a,b --stat m[,m] [--speedup]\n");
        return 2;
    }

    char *gcols[MAX_GROUP]; int ng = 0;
    for (char *t = strtok(group_arg, ","); t && ng < MAX_GROUP; t = strtok(NULL, ","))
        gcols[ng++] = t;
    char *scols[MAX_STAT]; int ns = 0;
    for (char *t = strtok(stat_arg, ","); t && ns < MAX_STAT; t = strtok(NULL, ","))
        scols[ns++] = t;

    FILE *fin = strcmp(in, "-") ? fopen(in, "r") : stdin;
    if (!fin) { fprintf(stderr, "cannot open %s\n", in); return 1; }

    char line[4096];
    if (!fgets(line, sizeof line, fin)) { fprintf(stderr, "empty input\n"); return 1; }
    char hdr[4096]; strcpy(hdr, line);
    char *hf[MAX_COLS];
    int nh = split(trim(hdr), hf, MAX_COLS);
    for (int i = 0; i < nh; i++) hf[i] = trim(hf[i]);

    int gidx[MAX_GROUP], sidx[MAX_STAT], var_in_group = -1;
    for (int g = 0; g < ng; g++) {
        gidx[g] = -1;
        for (int i = 0; i < nh; i++) if (!strcmp(hf[i], gcols[g])) gidx[g] = i;
        if (gidx[g] < 0) { fprintf(stderr, "group column '%s' not in header\n", gcols[g]); return 1; }
        if (!strcmp(gcols[g], "variant")) var_in_group = g;
    }
    for (int s = 0; s < ns; s++) {
        sidx[s] = -1;
        for (int i = 0; i < nh; i++) if (!strcmp(hf[i], scols[s])) sidx[s] = i;
        if (sidx[s] < 0) { fprintf(stderr, "stat column '%s' not in header\n", scols[s]); return 1; }
    }

    group_t *groups = NULL; int ngroups = 0, gcap = 0;

    while (fgets(line, sizeof line, fin)) {
        char *fields[MAX_COLS];
        char work[4096]; strcpy(work, line);
        int nf = split(trim(work), fields, MAX_COLS);
        if (nf < nh) continue; /* skip malformed / blank */

        char key[512] = {0};
        for (int g = 0; g < ng; g++) {
            strncat(key, trim(fields[gidx[g]]), sizeof(key) - strlen(key) - 2);
            strncat(key, "|", sizeof(key) - strlen(key) - 2);
        }
        /* find or create group */
        group_t *grp = NULL;
        for (int i = 0; i < ngroups; i++)
            if (!strcmp(groups[i].key, key)) { grp = &groups[i]; break; }
        if (!grp) {
            if (ngroups == gcap) {
                gcap = gcap ? gcap * 2 : 128;
                groups = realloc(groups, gcap * sizeof(group_t));
            }
            grp = &groups[ngroups++];
            memset(grp, 0, sizeof *grp);
            strcpy(grp->key, key);
            for (int g = 0; g < ng; g++)
                snprintf(grp->gvals[g], sizeof grp->gvals[g], "%s", trim(fields[gidx[g]]));
        }
        for (int s = 0; s < ns; s++) {
            if (grp->nvals[s] == grp->cap[s]) {
                grp->cap[s] = grp->cap[s] ? grp->cap[s] * 2 : 16;
                grp->vals[s] = realloc(grp->vals[s], grp->cap[s] * sizeof(double));
            }
            grp->vals[s][grp->nvals[s]++] = atof(trim(fields[sidx[s]]));
        }
        grp->reps++;
    }
    if (fin != stdin) fclose(fin);

    for (int i = 0; i < ngroups; i++) {
        group_t *g = &groups[i];
        for (int s = 0; s < ns; s++) {
            qsort(g->vals[s], g->nvals[s], sizeof(double), cmp_double);
            g->median[s] = percentile(g->vals[s], g->nvals[s], 0.50);
            g->q25[s]    = percentile(g->vals[s], g->nvals[s], 0.25);
            g->q75[s]    = percentile(g->vals[s], g->nvals[s], 0.75);
        }
        g->reps /= (ns ? 1 : 1);
    }

    /* speedup_vs_scalar: match the scalar sibling (same group key w/o variant). */
    int eps_stat = -1;
    for (int s = 0; s < ns; s++) if (!strcmp(scols[s], "elems_per_s")) eps_stat = s;
    if (want_speedup && (var_in_group < 0 || eps_stat < 0)) {
        fprintf(stderr, "--speedup needs 'variant' in --group and 'elems_per_s' in --stat\n");
        return 1;
    }
    if (want_speedup) {
        for (int i = 0; i < ngroups; i++) {
            /* build the sibling key with variant replaced by scalar */
            char sib[512] = {0};
            for (int g = 0; g < ng; g++) {
                strncat(sib, (g == var_in_group) ? "scalar" : groups[i].gvals[g],
                        sizeof(sib) - strlen(sib) - 2);
                strncat(sib, "|", sizeof(sib) - strlen(sib) - 2);
            }
            double scalar_med = 0.0;
            for (int j = 0; j < ngroups; j++)
                if (!strcmp(groups[j].key, sib)) { scalar_med = groups[j].median[eps_stat]; break; }
            groups[i].speedup = (scalar_med > 0.0) ? groups[i].median[eps_stat] / scalar_med : 0.0;
        }
    }

    FILE *fout = strcmp(out, "-") ? fopen(out, "w") : stdout;
    if (!fout) { fprintf(stderr, "cannot open %s\n", out); return 1; }
    for (int g = 0; g < ng; g++) fprintf(fout, "%s%s", g ? "," : "", gcols[g]);
    for (int s = 0; s < ns; s++)
        fprintf(fout, ",%s_median,%s_q25,%s_q75", scols[s], scols[s], scols[s]);
    fprintf(fout, ",reps");
    if (want_speedup) fprintf(fout, ",speedup_vs_scalar");
    fprintf(fout, "\n");

    for (int i = 0; i < ngroups; i++) {
        group_t *g = &groups[i];
        for (int c = 0; c < ng; c++) fprintf(fout, "%s%s", c ? "," : "", g->gvals[c]);
        for (int s = 0; s < ns; s++)
            fprintf(fout, ",%.6e,%.6e,%.6e", g->median[s], g->q25[s], g->q75[s]);
        fprintf(fout, ",%d", g->reps);
        if (want_speedup) fprintf(fout, ",%.6f", g->speedup);
        fprintf(fout, "\n");
    }
    if (fout != stdout) fclose(fout);
    fprintf(stderr, "summarize: %d groups -> %s\n", ngroups, out);
    return 0;
}
