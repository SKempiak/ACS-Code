#!/usr/bin/env bash
# tables.sh — derive the small report tables from processed data (no measuring).
#
#   scripts/tables.sh        (called by run.sh after locality / stride / ceilings, and by
#                             `run.sh derive`)
#
# Outputs (data/processed/), preformatted strings so the report typesets them as-is:
#   locality_levels.csv  level,n,footprint,scalar,autovec,native,triad
#       effective SAXPY bandwidth in GiB/s at one N per level, from locality.csv
#       (12 B/element: read x, read y, write y), next to the measured triad roof
#       for that level (ceilings_bw.csv, actual traffic: explicit loads+stores in
#       L1, where stores hit and need no write-allocate; incl. write-allocate in
#       L2/L3/DRAM) when available.
#   stride_summary.csv   n,pattern,scalar,autovec,native,speedup
#       time per processed element (ns) from stride.csv; speedup = scalar / best
#       SIMD-capable native time for that pattern.
#   baseline_gflops.csv  kernel,variant,L1,L2,L3,DRAM
#       median GFLOP/s from baseline.csv at N = 1024, 16384, 524288, 16777216
#       (the same per-level sizes as the roofline points).
#   dtype_summary.csv    kernel,dtype,autovec_1k,native_1k,native_16k,native_16m
#       speedup over scalar from dtype.csv at N = 1024 (autovec and native),
#       16384 and 16777216 (native).
#   stride_bw.csv        n,stride,native_ns,useful,fetched
#       native strided SAXPY in GiB/s: useful = 12 B per processed element / time;
#       fetched = cache-line traffic, 3 x min(4*stride, 64) B per element (a line
#       of x and of y read, the dirty y line written back) / time.
# Missing values are written as "--".
set -euo pipefail
cd "$(dirname "$0")/.."
P="data/processed"

if [ -s "$P/locality.csv" ]; then
  triad_file="$P/ceilings_bw.csv"; [ -s "$triad_file" ] || triad_file=/dev/null
  awk -F, -v OFS=, -v tf="$triad_file" '
    BEGIN {
      while ((getline line < tf) > 0) {
        split(line, f, ",")
        if (f[1] == "level") { for (i in f) tc[f[i]] = i; continue }
        if ("triad_total" in tc) triad[f[1]] = f[tc[f[1] == "L1" ? "triad" : "triad_total"]]
      }
      want[2048] = "L1"; want[16384] = "L2"; want[524288] = "L3"; want[33554432] = "DRAM"
    }
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    ($(c["n"]) in want) { g[$(c["n"]), $(c["variant"])] = $(c["elems_per_s_median"]) * 12 / 1073741824 }
    function fmt(v) { return (v == "" ? "--" : sprintf("%.1f", v)) }
    END {
      print "level,n,footprint,scalar,autovec,native,triad"
      split("2048 16384 524288 33554432", ns, " ")
      split("16 KiB,128 KiB,4 MiB,256 MiB", fp, ",")
      for (k = 1; k <= 4; k++) {
        n = ns[k]; L = want[n]
        print L, n, fp[k], fmt(g[n, "scalar"]), fmt(g[n, "autovec"]), fmt(g[n, "native"]),
              ((L in triad) ? sprintf("%.1f", triad[L]) : "--")
      }
    }' "$P/locality.csv" > "$P/locality_levels.csv"
  echo "tables: $P/locality_levels.csv"
fi

if [ -s "$P/stride.csv" ]; then
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    {
      n = $(c["n"]); a = $(c["access"]); s = $(c["stride"]); v = $(c["variant"])
      p = (a == "stride") ? "stride " s : a
      if (a == "stride" && s == 1) next          # unit row comes from access=unit
      if (a == "gather_avx2") { p = "gather"; v = "native_avx2" }
      t[n, p, v] = $(c["ns_per_elem_median"]); seen[n] = 1
    }
    function fmt(x) { return (x == "" ? "--" : sprintf("%.3f", x)) }
    END {
      print "n,pattern,scalar,autovec,native,native_avx2,speedup"
      split("unit,stride 2,stride 4,stride 8,stride 16,gather", pat, ",")
      split("32768 4194304", ns, " ")
      for (k = 1; k <= 2; k++) {
        n = ns[k]; if (!(n in seen)) continue
        for (q = 1; q <= 6; q++) {
          p = pat[q]; sc = t[n, p, "scalar"]; na = t[n, p, "native"]; ag = t[n, p, "native_avx2"]
          best = na; if (ag != "" && (best == "" || ag + 0 < best + 0)) best = ag
          sp = (sc != "" && best != "") ? sprintf("%.2f", sc / best) : "--"
          print n, p, fmt(sc), fmt(t[n, p, "autovec"]), fmt(na), fmt(ag), sp
        }
      }
    }' "$P/stride.csv" > "$P/stride_summary.csv"
  echo "tables: $P/stride_summary.csv"
fi

if [ -s "$P/stride.csv" ]; then
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; print "n,stride,native_ns,useful,fetched"; next }
    $(c["access"]) == "stride" && $(c["variant"]) == "native" {
      s = $(c["stride"]); t = $(c["ns_per_elem_median"]); line = (4 * s < 64) ? 4 * s : 64
      printf "%s,%s,%.3f,%.1f,%.1f\n", $(c["n"]), s, t, 12 / t / 1.073741824, 3 * line / t / 1.073741824
    }' "$P/stride.csv" > "$P/stride_bw.csv"
  echo "tables: $P/stride_bw.csv"
fi

if [ -s "$P/baseline.csv" ]; then
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    { g[$(c["kernel"]), $(c["variant"]), $(c["n"])] = $(c["gflops_median"]) }
    function fmt(x) { return (x == "" ? "--" : sprintf("%.2f", x)) }
    END {
      print "kernel,variant,L1,L2,L3,DRAM"
      split("saxpy dot mul stencil", ks, " "); split("SAXPY,dot,multiply,stencil", kn, ",")
      split("scalar autovec native", vs, " ")
      for (i = 1; i <= 4; i++) for (j = 1; j <= 3; j++) {
        k = ks[i]; v = vs[j]
        print (j == 1 ? kn[i] : ""), v, fmt(g[k, v, 1024]), fmt(g[k, v, 16384]),
              fmt(g[k, v, 524288]), fmt(g[k, v, 16777216])
      }
    }' "$P/baseline.csv" > "$P/baseline_gflops.csv"
  echo "tables: $P/baseline_gflops.csv"
fi

if [ -s "$P/dtype.csv" ]; then
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    { s[$(c["kernel"]), $(c["dtype"]), $(c["variant"]), $(c["n"])] = $(c["speedup_vs_scalar"]) }
    function fmt(x) { return (x == "" ? "--" : sprintf("%.2f", x)) }
    END {
      print "kernel,dtype,autovec_1k,native_1k,native_16k,native_16m"
      split("saxpy:f32 saxpy:f64 mul:f32 mul:f64 mul:i32 stencil:f32 stencil:f64", rows, " ")
      for (r = 1; r <= 7; r++) {
        split(rows[r], kd, ":"); k = kd[1]; d = kd[2]
        name = (k == "mul") ? "multiply" : (k == "saxpy" ? "SAXPY" : k)
        dn = (d == "f32") ? "float32" : (d == "f64" ? "float64" : "int32")
        print name, dn, fmt(s[k, d, "autovec", 1024]), fmt(s[k, d, "native", 1024]),
              fmt(s[k, d, "native", 16384]), fmt(s[k, d, "native", 16777216])
      }
    }' "$P/dtype.csv" > "$P/dtype_summary.csv"
  echo "tables: $P/dtype_summary.csv"
fi
