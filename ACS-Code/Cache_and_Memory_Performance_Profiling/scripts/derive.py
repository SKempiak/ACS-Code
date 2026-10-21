#!/usr/bin/env python3
"""derive.py — derived quantities for the Project 2 report (stdlib only).

    python3 scripts/derive.py data/processed

Reads whatever processed CSVs exist (tools/summarize output: <metric>_median /
_q25 / _q75 per configuration) and writes, next to them:

  summary.csv           key,value   every number quoted in the report's prose
                                    (read by ACS-Latex via \\val{key}; a missing key
                                    prints as a \\tbd marker, so the report never
                                    quotes a stale hand-copied number)
  zero_queue_table.csv  per-level plateau latency (primary method), cross-check
  littles_law.csv       intensity sweep: lambda, measured loaded W, L = lambda*W
  mlp_littles.csv       known-concurrency chase sweep: N = T*k vs L_mem = lambda*W_mem (probe)
  knee.csv / knee_ref.csv  the knee point and the 2x-unloaded reference line
  amat_fit.csv          cache_miss: measured vs AMAT-model ns/element

Rules (stated in the report):
  * Plateau of a cache level = median, over the measured working-set sizes s with
    2*C_prev <= s <= 0.75*C_level, of the per-size median latency (C_prev = 4 KiB
    for L1). DRAM = sizes >= 4 * C_L3. This avoids the transition points at each
    capacity edge (e.g. 256 KiB is *not* an L2 point).
  * Knee = the lowest-throughput point of the loaded-latency curve whose probe
    latency is >= 2x the unloaded (T=0) latency; its throughput is interpolated
    linearly between that point and the previous one at exactly 2x. The point of
    maximum throughput/latency ("power") is reported as a second criterion.
  * AMAT fit (per traversal order): ns/elem = t0 + a2*(L2 hits) + a3*(L3 hits)
    + aD*(DRAM misses), with per-element counts from the user-space counters:
    L2 hits = L1D misses - LLC refs, L3 hits = LLC refs - LLC misses,
    DRAM = LLC misses. Ordinary least squares; R^2 reported.
"""
import csv
import math
import os
import sys

KIB, MIB = 1024, 1024 * 1024
# ns -> core cycles. Runs were taken with turbo disabled and the performance governor, so the core
# clock is the fixed 2.8 GHz base frequency (= the TSC rate). The in-process add-chain probe
# (`ghz` column) is NOT used: in the 2026-10-21 data it reads either ~2.79 or ~2.41 GHz run to run,
# while the user-mode cycle counter over the same timed windows gives ~2.77 GHz for both groups
# (see ws_ctr_ghz / ws_ctr_ghz_lowprobe below), i.e. the low readings are a probe artifact.
F_NOM_GHZ = float(os.environ.get("P2_CORE_GHZ", "2.8"))
C_L1, C_L2, C_L3 = 32 * KIB, 256 * KIB, 20 * MIB      # i9-10900F per-core L1d/L2, shared L3
LINE = 64
GIB = 1024.0 ** 3


# ----------------------------------------------------------------- helpers
def read(proc, name):
    path = os.path.join(proc, name + ".csv")
    if not os.path.exists(path):
        return None
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def num(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return math.nan
    return v


def ok(v):
    return v is not None and not (isinstance(v, float) and (math.isnan(v) or math.isinf(v)))


def median(vals):
    v = sorted(x for x in vals if ok(x))
    if not v:
        return math.nan
    n = len(v)
    return v[n // 2] if n % 2 else 0.5 * (v[n // 2 - 1] + v[n // 2])


def fmt(v, digits=3):
    """Significant-figure formatting suitable for siunitx \\num."""
    if not ok(v):
        return None
    if v == 0:
        return "0"
    mag = math.floor(math.log10(abs(v)))
    dec = max(0, digits - 1 - mag)
    return f"{v:.{dec}f}"


def rows_where(rows, **kw):
    out = []
    for r in rows or []:
        if all(str(r.get(k)) == str(v) for k, v in kw.items()):
            out.append(r)
    return out


def write_csv(proc, name, header, rows):
    with open(os.path.join(proc, name + ".csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow(["nan" if (isinstance(x, float) and not ok(x)) else x for x in r])


def solve(A, b):
    """Gaussian elimination with partial pivoting; returns None if singular."""
    n = len(A)
    M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-12:
            return None
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, n + 1):
                    M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]


def ols(X, y):
    k = len(X[0])
    A = [[sum(x[i] * x[j] for x in X) for j in range(k)] for i in range(k)]
    b = [sum(x[i] * yy for x, yy in zip(X, y)) for i in range(k)]
    beta = solve(A, b)
    if beta is None:
        return None, math.nan
    pred = [sum(bi * xi for bi, xi in zip(beta, x)) for x in X]
    ybar = sum(y) / len(y)
    ss_tot = sum((yy - ybar) ** 2 for yy in y)
    ss_res = sum((yy - p) ** 2 for yy, p in zip(y, pred))
    return beta, (1 - ss_res / ss_tot) if ss_tot > 0 else math.nan


# ----------------------------------------------------------------- sections
def zero_queue(proc, S):
    rows = read(proc, "zero_queue")
    if not rows:
        return
    # range labels must not contain commas (pgfplotstable reads col sep=comma)
    levels = [("L1", 8 * KIB, int(0.75 * C_L1), "8--24 KiB"),
              ("L2", 2 * C_L1, int(0.75 * C_L2), "64--192 KiB"),
              ("L3", 2 * C_L2, int(0.75 * C_L3), "0.5--15 MiB"),
              ("DRAM", 4 * C_L3, 1 << 62, r"$\geq$80 MiB")]

    def plateau(sel, lo, hi, col):
        return median([num(r[col + "_median"]) for r in sel if lo <= int(r["bytes"]) <= hi])

    prim = rows_where(rows, pattern="random", pages="4k", gen="lcg", timer="clock")
    xchk = rows_where(rows, pattern="random", pages="4k", gen="xorshift", timer="tsc")
    huge = rows_where(rows, pattern="random", pages="huge", gen="lcg", timer="clock")
    out = []
    for name, lo, hi, label in levels:
        sel = [r for r in prim if lo <= int(r["bytes"]) <= hi]
        ns = plateau(prim, lo, hi, "ns_per_access")
        cyc = ns * F_NOM_GHZ if ok(ns) else math.nan
        vals = [num(r["ns_per_access_median"]) for r in sel]
        xns = plateau(xchk, lo, hi, "ns_per_access")
        hns = plateau(huge, lo, hi, "ns_per_access") if name == "DRAM" else math.nan
        diff = 100.0 * (xns - ns) / ns if ok(ns) and ok(xns) else math.nan
        out.append([name, label, len(sel), fmt(ns), fmt(cyc), fmt(min(vals)) if vals else "nan",
                    fmt(max(vals)) if vals else "nan", fmt(xns), fmt(diff, 2), fmt(hns)])
        for key, v, d in (("ns", ns, 3), ("cyc", cyc, 3), ("xns", xns, 3), ("xdiff", diff, 2),
                          ("hugens", hns, 3)):
            S[f"zq_{name}_{key}"] = fmt(v, d)
        if vals:
            S[f"zq_{name}_min"] = fmt(min(vals))
            S[f"zq_{name}_max"] = fmt(max(vals))
    write_csv(proc, "zero_queue_table",
              ["level", "range", "nsizes", "ns", "cycles", "ns_min", "ns_max", "xcheck_ns",
               "xcheck_diff_pct", "huge_ns"], out)
    for r in prim:
        if r["bytes"] == "268435456":
            S["zq_DRAM256_ns"] = fmt(num(r["ns_per_access_median"]))
    d4 = num(S.get("zq_DRAM_ns")); dh = num(S.get("zq_DRAM_hugens"))
    if ok(d4) and ok(dh):
        S["zq_DRAM_walk_ns"] = fmt(d4 - dh)
    S["zq_ghz"] = fmt(F_NOM_GHZ)
    # what the add-chain probe would have given (median over sizes, and its low mode)
    pg = [num(r.get("cycles_per_access_median")) / num(r.get("ns_per_access_median")) for r in prim]
    pg = [g for g in pg if ok(g)]
    if pg:
        S["zq_probe_ghz_max"] = fmt(max(pg)); S["zq_probe_ghz_min"] = fmt(min(pg))
        S["zq_DRAM_cyc_probe"] = fmt(plateau(prim, 4 * C_L3, 1 << 62, "cycles_per_access"))


def working_set(proc, S):
    rows = read(proc, "working_set")
    if not rows:
        return
    def at(pattern, pages, b, col):
        r = rows_where(rows, pattern=pattern, pages=pages, bytes=b)
        return num(r[0][col + "_median"]) if r else math.nan
    big = 536870912
    S["ws_dram_rand4k_ns"] = fmt(at("random", "4k", big, "ns_per_access"))
    S["ws_dram256_rand4k_ns"] = fmt(at("random", "4k", 268435456, "ns_per_access"))
    freq_check(proc, S)
    S["ws_dram_randhuge_ns"] = fmt(at("random", "huge", big, "ns_per_access"))
    S["ws_dram_seq_ns"] = fmt(at("sequential", "4k", big, "ns_per_access"))
    S["ws_dram_rand4k_dtlb"] = fmt(at("random", "4k", big, "ctr_dtlb_miss_pa"))
    S["ws_dram_rand4k_l1d"] = fmt(at("random", "4k", big, "ctr_l1d_miss_pa"))
    S["ws_dram_randhuge_l1d"] = fmt(at("random", "huge", big, "ctr_l1d_miss_pa"))
    S["ws_dram_rand_llcmiss"] = fmt(at("random", "huge", big, "ctr_llc_miss_pa"))
    S["ws_dram_seq_llcmiss"] = fmt(at("sequential", "4k", big, "ctr_llc_miss_pa"))
    S["ws_l2edge_4k_ns"] = fmt(at("random", "4k", 196608, "ns_per_access"))
    S["ws_l2edge_huge_ns"] = fmt(at("random", "huge", 196608, "ns_per_access"))
    S["ws_l2edge_4k_llcref"] = fmt(at("random", "4k", 196608, "ctr_llc_ref_pa"))
    S["ws_l2edge_huge_llcref"] = fmt(at("random", "huge", 196608, "ctr_llc_ref_pa"))
    cov = [num(r.get("ctr_cover_median")) for r in rows]
    if any(ok(c) for c in cov):
        S["ws_ctr_cover_min"] = fmt(min(c for c in cov if ok(c)))


def freq_check(proc, S):
    """Core clock during the timed windows, from the raw working_set rows: user-mode cycle
    counter / wall time, split by what the add-chain probe (`ghz`) reported for that run."""
    import glob
    dirs = sorted(glob.glob(os.path.join(proc, "..", "raw", "working_set", "*", "raw.csv")))
    if not dirs:
        return
    hi, lo, nlo, n = [], [], 0, 0
    with open(dirs[-1], newline="") as f:
        for r in csv.DictReader(f):
            g, c, t = num(r.get("ghz")), num(r.get("ctr_cycles_pa")), num(r.get("ns_per_access"))
            if not (ok(g) and ok(c) and ok(t)) or t <= 0:
                continue
            n += 1
            (lo if g < 2.7 else hi).append(c / t)
            nlo += g < 2.7
    if hi + lo:
        S["ws_ctr_ghz"] = fmt(median(hi + lo))
    if hi:
        S["ws_ctr_ghz_hiprobe"] = fmt(median(hi))
    if lo:
        S["ws_ctr_ghz_lowprobe"] = fmt(median(lo))
    if n:
        S["ws_probe_low_pct"] = fmt(100.0 * nlo / n, 2)


def clock_check(proc, S):
    """Diagnostic run of build/clock_check: core clock, fraction of wall time the pinned thread
    actually executes, add-chain probe reading, and ACPI GPE activity per window."""
    import glob
    files = sorted(glob.glob(os.path.join(proc, "..", "raw", "clock_check", "*", "raw.csv")))
    if not files:
        return
    rows = list(csv.DictReader(open(files[-1], newline="")))
    if not rows:
        return
    gpe = [r for r in rows if num(r["gpe"]) > 0]
    quiet = [r for r in rows if num(r["gpe"]) == 0]
    S["cc_core_ghz"] = fmt(median([num(r["core_ghz"]) for r in rows]))
    S["cc_windows"] = str(len(rows))
    S["cc_gpe_pct"] = fmt(100.0 * len(gpe) / len(rows), 2)
    for tag, sel in (("gpe", gpe), ("quiet", quiet)):
        if sel:
            S[f"cc_userfrac_{tag}"] = fmt(median([num(r["user_frac"]) for r in sel]), 3)
            S[f"cc_core_ghz_{tag}"] = fmt(median([num(r["core_ghz"]) for r in sel]))
            pr = [num(r["probe_ghz"]) for r in sel if r["kind"] == "probe"]
            if pr:
                S[f"cc_probe_{tag}"] = fmt(median(pr))
    g = [num(r["gpe"]) for r in gpe]
    if g:
        S["cc_gpe_per_window"] = fmt(median(g), 3)
        S["cc_window_ms"] = fmt(1000 * median([num(r["wall_s"]) for r in rows]), 3)


def pattern(proc, S):
    lat = read(proc, "pattern_lat")
    for r in lat or []:
        p = "seq" if r["pattern"] == "sequential" else "rand"
        S[f"pat_lat_{p}_{r['access']}_ns"] = fmt(num(r["ns_per_access_median"]))
        S[f"pat_lat_{p}_{r['access']}_gib"] = fmt(num(r["gib_s_median"]))
    bw = read(proc, "pattern_bw")
    for r in bw or []:
        p = "seq" if r["pattern"] == "sequential" else "rand"
        g = num(r["gib_s_median"])
        if r["access"] != "0":
            S[f"pat_bw_{p}_{r['access']}"] = fmt(g)
        else:
            s = int(r["strideb"])
            S[f"pat_stride_{p}_{s}"] = fmt(g)
            # one 8 B element used per stride; every touched line moves 64 B
            line = g * (LINE / 8.0) if s >= LINE else g
            S[f"pat_stride_{p}_{s}_line"] = fmt(line)
    if bw:
        seqs = [num(v) for k, v in S.items() if k.startswith("pat_bw_seq_")]
        if seqs:
            S["pat_bw_seq_max"] = fmt(max(seqs))
        a = num(S.get("pat_stride_seq_64_line")); b = num(S.get("pat_stride_seq_8"))
        c = num(S.get("pat_bw_seq_64"))
        if ok(a) and ok(b):
            S["pat_stride64_over_unit"] = fmt(a / b)
        if ok(c) and ok(b):
            S["pat_vec_over_scalar"] = fmt(c / b)
        for acc in ("64", "256", "1024"):
            s_, r_ = num(S.get(f"pat_bw_seq_{acc}")), num(S.get(f"pat_bw_rand_{acc}"))
            if ok(s_) and ok(r_):
                S[f"pat_bw_ratio_{acc}"] = fmt(s_ / r_)


def rw_mix(proc, S):
    rows = read(proc, "rw_mix")
    for r in rows or []:
        t, rd = r["threads"], r["reads10"]
        if t == "0":
            S["rw_unloaded_ns"] = fmt(num(r["probe_ns_median"]))
            continue
        tag = f"rw_{rd}_t{t}"
        S[tag + "_gib"] = fmt(num(r["total_gib_s_median"]))
        S[tag + "_traffic"] = fmt(num(r["traffic_gib_s_median"]))
        S[tag + "_ns"] = fmt(num(r["probe_ns_median"]))
    for t in ("1", "9"):
        v = [num(r["probe_ns_median"]) for r in rows or [] if r["threads"] == t]
        v = [x for x in v if ok(x)]
        if v:
            S[f"rw_t{t}_ns_min"] = fmt(min(v)); S[f"rw_t{t}_ns_max"] = fmt(max(v))
    ref = read(proc, "rw_mix_ref")
    for r in ref or []:
        S[f"rw_ref_{r['kernel']}"] = fmt(num(r["gib_s_median"]))


def intensity(proc, S):
    rows = read(proc, "intensity_loaded")
    if rows:
        pts = []
        for r in rows:
            pts.append(dict(t=int(r["threads"]), d=int(r["delay"]),
                            bw=num(r["total_gib_s_median"]), w=num(r["probe_ns_median"]),
                            wq25=num(r["probe_ns_q25"]), wq75=num(r["probe_ns_q75"]),
                            L=num(r["little_l_median"])))
        base = [p for p in pts if p["t"] == 0 and p["d"] == 0]
        w0 = base[0]["w"] if base else math.nan
        S["int_w0_ns"] = fmt(w0)
        peak = max(pts, key=lambda p: p["bw"])
        S["int_peak_gib"] = fmt(peak["bw"])
        S["int_peak_ns"] = fmt(peak["w"])
        S["int_peak_threads"] = str(peak["t"])
        if ok(w0):
            S["int_peak_ratio"] = fmt(peak["w"] / w0)
        # Offered load must be ordered by the *knob*, not by delivered bandwidth (bandwidth is
        # flat/noisy past saturation, so sorting by it scrambles the curve):
        #   thread sweep: T = 0..9, delay 0;  delay sweep: T = 9, delay decreasing (more load).
        tsweep = sorted((p for p in pts if p["d"] == 0), key=lambda p: p["t"])
        dsweep = [p for p in pts if p["t"] == 0 and p["d"] == 0] + \
                 sorted((p for p in pts if p["t"] == max(q["t"] for q in pts)), key=lambda p: -p["d"])

        def crossing(seq):
            for i, p in enumerate(seq):
                if ok(p["w"]) and p["w"] >= 2 * w0:
                    q = seq[i - 1] if i > 0 else p
                    if q is not p and p["w"] != q["w"]:
                        f = (2 * w0 - q["w"]) / (p["w"] - q["w"])
                        return dict(bw=q["bw"] + f * (p["bw"] - q["bw"]), w=2 * w0, at=p, prev=q)
                    return dict(bw=p["bw"], w=2 * w0, at=p, prev=p)
            return None
        # criterion 1: latency >= 2x unloaded, along the thread sweep
        knee = crossing(tsweep) if ok(w0) else None
        kd = crossing(dsweep) if ok(w0) else None
        if kd:
            S["int_kneed_gib"] = fmt(kd["bw"]); S["int_kneed_delay"] = str(kd["at"]["d"])
            S["int_kneed_prevdelay"] = str(kd["prev"]["d"])
        # bandwidth saturation: first T reaching 95% of the peak
        sat = next((p for p in tsweep if p["bw"] >= 0.95 * peak["bw"]), None)
        if sat:
            S["int_sat_threads"] = str(sat["t"]); S["int_sat_gib"] = fmt(sat["bw"])
            S["int_sat_ns"] = fmt(sat["w"])
            if ok(w0):
                S["int_sat_ratio"] = fmt(sat["w"] / w0)
        if tsweep:
            last = tsweep[-1]
            S["int_last_threads"] = str(last["t"]); S["int_last_gib"] = fmt(last["bw"])
            S["int_last_ns"] = fmt(last["w"])
        S["int_knee_reached"] = "yes" if knee else "no"
        if knee:
            S["int_knee_gib"] = fmt(knee["bw"])
            S["int_knee_ns"] = fmt(knee["w"])
            S["int_knee_frac"] = fmt(100.0 * knee["bw"] / peak["bw"], 2)
            S["int_knee_threads"] = str(knee["at"]["t"])
            S["int_knee_prevthreads"] = str(knee["prev"]["t"])
            S["int_knee_delay"] = str(knee["at"]["d"])
            S["int_knee_lines"] = fmt(knee["bw"] * GIB / LINE * knee["w"] * 1e-9)
            write_csv(proc, "knee", ["gib_s", "ns"], [[knee["bw"], knee["w"]]])
        if ok(w0):
            write_csv(proc, "knee_ref", ["gib_s", "ns"], [[0.0, 2 * w0], [peak["bw"] * 1.05, 2 * w0]])
        # criterion 2: max throughput / latency
        pw = max((p for p in pts if ok(p["w"]) and p["w"] > 0), key=lambda p: p["bw"] / p["w"])
        S["int_power_gib"] = fmt(pw["bw"]); S["int_power_ns"] = fmt(pw["w"])
        S["int_power_threads"] = str(pw["t"]); S["int_power_delay"] = str(pw["d"])
        # Little's Law table: delay = 0 thread sweep
        ll = []
        for p in sorted((p for p in pts if p["d"] == 0), key=lambda p: p["t"]):
            lam = p["bw"] * GIB / LINE / 1e6             # Mlines/s
            L = lam * 1e6 * p["w"] * 1e-9
            L0 = lam * 1e6 * w0 * 1e-9 if ok(w0) else math.nan
            ll.append([p["t"], p["bw"], lam, p["w"], L, L0])
            if p["t"] > 0:
                S[f"int_t{p['t']}_gib"] = fmt(p["bw"])
                S[f"int_t{p['t']}_ns"] = fmt(p["w"])
                S[f"int_t{p['t']}_L"] = fmt(L)
                S[f"int_t{p['t']}_L0"] = fmt(L0)
        write_csv(proc, "littles_law", ["threads", "gib_s", "mlines_s", "w_ns", "L", "L0"], ll)
        if ll:
            S["int_Lmax"] = fmt(max(r[4] for r in ll))
            S["int_L0max"] = fmt(max(r[5] for r in ll))
    mlp = read(proc, "intensity_mlp")
    if mlp:
        # NOTE: lambda * (per-chain step time) == N by construction (an accounting identity, not a
        # test of Little's Law). The informative quantity is L_mem = lambda * W_mem, with W_mem the
        # latency of a memory request measured by the concurrent probe: the number of lines actually
        # in flight in the memory system. Chains beyond that wait inside the core.
        out = []
        for r in mlp:
            t, k = int(r["threads"]), int(r["chains"])
            lam = num(r["gen_gib_s_median"]) * GIB / LINE / 1e6
            W = num(r["gen_lat_ns_median"]); L = num(r["little_l_median"])
            wm = num(r.get("probe_ns_median"))
            lmem = lam * 1e6 * wm * 1e-9 if ok(wm) else math.nan
            out.append([t, k, t * k, num(r["gen_gib_s_median"]), lam, W, L,
                        L / (t * k) if ok(L) else math.nan, wm, lmem])
        # per-repetition IQR of bandwidth and L_mem, from the raw rows (pgfplots error bars)
        import glob
        raws = sorted(glob.glob(os.path.join(proc, "..", "raw", "intensity", "*", "raw_mlp.csv")))
        reps = {}
        if raws:
            with open(raws[-1], newline="") as f:
                for r in csv.DictReader(f):
                    key = (int(r["threads"]), int(r["chains"]))
                    g, w = num(r["gen_gib_s"]), num(r["probe_ns"])
                    reps.setdefault(key, []).append((g, g * GIB / LINE * w * 1e-9 if ok(w) else math.nan))

        def q(v, p):
            v = sorted(x for x in v if ok(x))
            if not v:
                return math.nan
            i = p * (len(v) - 1); lo = int(i)
            return v[lo] if lo + 1 >= len(v) else v[lo] + (i - lo) * (v[lo + 1] - v[lo])
        for o in out:
            rr = reps.get((o[0], o[1]), [])
            if rr:   # L_mem as the median of per-repetition products, consistent with its IQR
                o[9] = q([b for _, b in rr], .5)
            o += [q([a for a, _ in rr], .25), q([a for a, _ in rr], .75),
                  q([b for _, b in rr], .25), q([b for _, b in rr], .75)]
        out.sort(key=lambda x: (x[0], x[1]))
        write_csv(proc, "mlp_littles", ["threads", "chains", "N", "gib_s", "mlines_s", "w_ns", "L",
                                        "L_over_N", "wmem_ns", "L_mem", "gib_s_q25", "gib_s_q75",
                                        "L_mem_q25", "L_mem_q75"], out)
        one = [o for o in out if o[0] == 1]
        if one:
            best = max(one, key=lambda o: o[3])
            S["mlp_t1_peak_gib"] = fmt(best[3]); S["mlp_t1_peak_k"] = str(best[1])
            S["mlp_t1_peak_ns"] = fmt(best[5])
            S["mlp_t1_Lmax"] = fmt(max(o[6] for o in one))
            lm = [o[9] for o in one if ok(o[9])]
            if lm:
                S["mlp_t1_Lmem_max"] = fmt(max(lm)); S["mlp_t1_Lmem_med"] = fmt(median(lm[2:] or lm))
            S["mlp_t1_wmem"] = fmt(median([o[8] for o in one]))
            last = one[-1]
            S["mlp_t1_last_k"] = str(last[1]); S["mlp_t1_last_ns"] = fmt(last[5])
            S["mlp_t1_last_gib"] = fmt(last[3])
            k1 = [o for o in one if o[1] == 1]
            if k1:
                S["mlp_k1_ns"] = fmt(k1[0][5]); S["mlp_k1_gib"] = fmt(k1[0][3])
            # concurrency where one core stops scaling: first k with < 5% gain
            prev = None
            for o in one:
                if prev and o[3] < 1.05 * prev[3]:
                    S["mlp_t1_sat_k"] = str(prev[1]); break
                prev = o
        ratios = [o[7] for o in out if ok(o[7])]
        if ratios:
            S["mlp_LN_min"] = fmt(min(ratios)); S["mlp_LN_max"] = fmt(max(ratios))
        allp = max(out, key=lambda o: o[3])
        S["mlp_peak_gib"] = fmt(allp[3]); S["mlp_peak_N"] = str(allp[2]); S["mlp_peak_ns"] = fmt(allp[5])
        S["mlp_peak_T"] = str(allp[0]); S["mlp_peak_Lmem"] = fmt(allp[9]); S["mlp_peak_wmem"] = fmt(allp[8])


def cache_miss(proc, S):
    rows = read(proc, "cache_miss_ctr")
    if not rows:
        return
    out = []
    for pat in ("sequential", "random"):
        sel = sorted(rows_where(rows, pattern=pat, pages="4k"), key=lambda r: int(r["n"]))
        if not sel:
            continue
        tag = "seq" if pat == "sequential" else "rand"
        lo, hi = num(sel[0]["ns_per_elem_median"]), num(sel[-1]["ns_per_elem_median"])
        S[f"cm_{tag}_min_ns"] = fmt(lo); S[f"cm_{tag}_max_ns"] = fmt(hi)
        if ok(lo) and ok(hi):
            S[f"cm_{tag}_span"] = fmt(hi / lo, 2)
        for key in ("ctr_l1d_miss_pe", "ctr_llc_miss_pe", "ctr_dtlb_miss_pe"):
            S[f"cm_{tag}_max_{key[4:-3]}"] = fmt(num(sel[-1][key + "_median"]))
        X, y, ns_ = [], [], []
        for r in sel:
            l1, lr, lm = (num(r[c + "_median"]) for c in ("ctr_l1d_miss_pe", "ctr_llc_ref_pe",
                                                           "ctr_llc_miss_pe"))
            t = num(r["ns_per_elem_median"])
            if not all(ok(v) for v in (l1, lr, lm, t)):
                continue
            X.append([1.0, max(l1 - lr, 0.0), max(lr - lm, 0.0), lm]); y.append(t)
            ns_.append(int(r["n"]))
        if len(X) >= 6:
            beta, r2 = ols(X, y)
            if beta:
                for name, b in zip(("t0", "a2", "a3", "aD"), beta):
                    S[f"amat_{tag}_{name}"] = fmt(b)
                S[f"amat_{tag}_r2"] = fmt(r2, 3)
                dram = num(S.get("zq_DRAM_ns"))
                if ok(dram) and beta[3] > 0:
                    S[f"amat_{tag}_mlp"] = fmt(dram / beta[3], 2)
                # exposed fraction per level: zero-queue latency / fitted cost = overlap factor
                for lvl, b in (("L2", beta[1]), ("L3", beta[2])):
                    z = num(S.get(f"zq_{lvl}_ns"))
                    if ok(z) and b > 0:
                        S[f"amat_{tag}_ovl{lvl}"] = fmt(z / b, 2)
                resid = [abs(t - sum(bb * xi for bb, xi in zip(beta, x))) / t for x, t in zip(X, y)]
                S[f"amat_{tag}_maxrelerr"] = fmt(100 * max(resid), 2)
                for n, x, t in zip(ns_, X, y):
                    out.append([n, pat, t, sum(b * xi for b, xi in zip(beta, x))])
    if out:
        write_csv(proc, "amat_fit", ["n", "pattern", "measured_ns", "predicted_ns"], out)
    s, r = num(S.get("cm_seq_max_ns")), num(S.get("cm_rand_max_ns"))
    if ok(s) and ok(r):
        S["cm_dram_gap"] = fmt(r / s, 2)


def tlb(proc, S):
    ch = read(proc, "tlb_chase")
    for r in ch or []:
        n = r["nodes"]; pg = r["pages"]
        if n in ("16", "64", "128", "1536", "2048", "4096", "16384", "65536"):
            S[f"tlb_{pg}_{n}_ns"] = fmt(num(r["ns_per_access_median"]))
            S[f"tlb_{pg}_{n}_dtlb"] = fmt(num(r["ctr_dtlb_miss_pa_median"]))
    for n in ("128", "1536", "2048", "4096", "16384", "65536"):
        a, b = num(S.get(f"tlb_4k_{n}_ns")), num(S.get(f"tlb_huge_{n}_ns"))
        if ok(a) and ok(b):
            S[f"tlb_gap_{n}_ns"] = fmt(a - b)
            S[f"tlb_gap_{n}_cyc"] = fmt((a - b) * F_NOM_GHZ)
            S[f"tlb_ratio_{n}"] = fmt(a / b, 3)
    sx = read(proc, "tlb_saxpy")
    for r in sx or []:
        if r["n"] == str(1 << 24):
            S[f"tlbs_{r['pages']}_ns"] = fmt(num(r["ns_per_elem_median"]))
            S[f"tlbs_{r['pages']}_dtlb"] = fmt(num(r["ctr_dtlb_miss_pe_median"]))
    a, b = num(S.get("tlbs_4k_ns")), num(S.get("tlbs_huge_ns"))
    if ok(a) and ok(b):
        S["tlbs_speedup"] = fmt(a / b, 3)


def pitfall(proc, S):
    rows = read(proc, "pitfall")
    if not rows:
        return
    rows = sorted(rows, key=lambda r: int(r["wss_bytes"]))
    S["pit_small_gib"] = fmt(num(rows[0]["gib_s_median"]))
    S["pit_small_kib"] = str(round(int(rows[0]["wss_bytes"]) / 1024))   # 16320 B -> 16
    S["pit_small_bytes"] = rows[0]["wss_bytes"]
    # DRAM-resident: >= 3x the LLC (the "64 MiB" point is 67108800 B after rounding to loop units)
    big = [num(r["gib_s_median"]) for r in rows if int(r["wss_bytes"]) >= 3 * C_L3]
    if big:
        S["pit_dram_lo"] = fmt(min(big)); S["pit_dram_hi"] = fmt(max(big))
        S["pit_ratio"] = fmt(num(rows[0]["gib_s_median"]) / median(big), 2)


def main():
    proc = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "data", "processed")
    S = {}
    for fn in (zero_queue, working_set, clock_check, pattern, rw_mix, intensity, cache_miss, tlb, pitfall):
        try:
            fn(proc, S)
        except (KeyError, ValueError, ZeroDivisionError) as e:   # schema drift: skip, don't die
            print(f"derive.py: {fn.__name__}: skipped ({e!r})", file=sys.stderr)
    keys = sorted(k for k, v in S.items() if v is not None)
    with open(os.path.join(proc, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["key", "value"])
        for k in keys:
            w.writerow([k, S[k]])
    print(f"derive.py: {len(keys)} values -> {os.path.join(proc, 'summary.csv')}", file=sys.stderr)


if __name__ == "__main__":
    main()
