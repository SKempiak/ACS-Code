#!/usr/bin/env bash
# roofline.sh — derive the roofline CSVs from already-processed data (no measuring).
#
#   scripts/roofline.sh            (also called by run.sh after `ceilings` and `baseline`)
#
# Inputs  (data/processed/):
#   ceilings.csv   measured peak FLOP rates and per-level STREAM bandwidths  (optional)
#   baseline.csv   kernel GFLOP/s across N                                   (optional)
# Outputs (data/processed/):
#   roofline_points.csv  kernel,variant,level,n,ai,gflops_median,gflops_q25,gflops_q75
#                        one point per kernel x variant at an N inside each cache level
#   roofline_roofs.csv   roof,ai,gflops   polylines: one bandwidth roof per level
#                        (triad, actual traffic at that level, see below) capped by
#                        the measured AVX2-FMA float32 peak, plus horizontal peak lines
#   ceilings_peak.csv    isa,gflops_median,gflops_q25,gflops_q75,flops_per_cycle,ghz
#   ceilings_bw.csv      level,bytes,read,copy,triad,copy_total,triad_total   (GiB/s medians)
#
# Arithmetic intensity uses actual traffic per element, float32. For L2, L3 and
# DRAM a store to a line that is not in L1 first reads it (write-allocate):
#   saxpy   2 FLOP / 12 B  (read x, read y, write y; y is read first, so no write-allocate)
#   mul     1 FLOP / 16 B  (read x, read y, write z + write-allocate read of z)
#   stencil 5 FLOP / 12 B  (read x once thanks to reuse, write y + write-allocate)
#   dot     2 FLOP /  8 B  (read x, read y; no store)
# and the triad roof is counted the same way (12 B explicit + 4 B write-allocate,
# column gib_per_s_total). With an L1-resident working set every store hits a
# line that is already in L1, so there is no write-allocate fill: the L1 roof is
# the triad's explicit load+store traffic (gib_per_s, 12 B) and the L1 points use
# explicit-traffic intensities (mul 1/12, stencil 5/8; saxpy and dot unchanged).
set -euo pipefail
cd "$(dirname "$0")/.."
P="data/processed"

# Representative N per level for float32 (footprint 8-12 B/elem):
#   L1 1024 (8-12 KiB), L2 16384 (128-192 KiB), L3 524288 (4-6 MiB), DRAM 16777216 (128-192 MiB)
if [ -s "$P/baseline.csv" ]; then
  awk -F, -v OFS=, '
    BEGIN {
      lvl[1024] = "L1"; lvl[16384] = "L2"; lvl[524288] = "L3"; lvl[16777216] = "DRAM"
      ai["saxpy"] = 2/12; ai["mul"] = 1/16; ai["stencil"] = 5/12; ai["dot"] = 2/8
      ai1["saxpy"] = 2/12; ai1["mul"] = 1/12; ai1["stencil"] = 5/8; ai1["dot"] = 2/8   # L1: no write-allocate
      print "kernel,variant,level,n,ai,gflops_median,gflops_q25,gflops_q75"
    }
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    ($(c["n"]) in lvl) && ($(c["kernel"]) in ai) {
      print $(c["kernel"]), $(c["variant"]), lvl[$(c["n"])], $(c["n"]),
            sprintf("%.6f", (lvl[$(c["n"])] == "L1") ? ai1[$(c["kernel"])] : ai[$(c["kernel"])]),
            $(c["gflops_median"]), $(c["gflops_q25"]), $(c["gflops_q75"])
    }' "$P/baseline.csv" > "$P/roofline_points.csv"
  echo "roofline: $P/roofline_points.csv"
fi

if [ -s "$P/ceilings.csv" ]; then
  # peak table
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i
              print "isa,gflops_median,gflops_q25,gflops_q75,flops_per_cycle,ghz"; next }
    $(c["bench"]) == "peak" {
      fpc = ("flops_per_cycle_median" in c) ? $(c["flops_per_cycle_median"]) : "NA"
      ghz = ("ghz_median" in c) ? $(c["ghz_median"]) : "NA"
      print $(c["isa"]), $(c["gflops_median"]), $(c["gflops_q25"]), $(c["gflops_q75"]), fpc, ghz
    }' "$P/ceilings.csv" > "$P/ceilings_peak.csv"

  # bandwidth table (per-level points only; the sweep is plotted from ceilings.csv)
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $(c["bench"]) != "peak" && $(c["label"]) != "sweep" {
      L = $(c["label"]); seen[L] = 1
      b[L, $(c["bench"])] = $(c["gib_per_s_median"])
      t[L, $(c["bench"])] = $(c["gib_per_s_total_median"])
      if ($(c["bench"]) == "triad") by[L] = $(c["bytes"])
    }
    END {
      print "level,bytes,read,copy,triad,copy_total,triad_total"
      n = split("L1 L2 L3 DRAM", order, " ")
      for (k = 1; k <= n; k++) {
        L = order[k]; if (!(L in seen)) continue
        print L, by[L], b[L, "read"], b[L, "copy"], b[L, "triad"], t[L, "copy"], t[L, "triad"]
      }
    }' "$P/ceilings.csv" > "$P/ceilings_bw.csv"

  # roofline polylines
  awk -F, -v OFS=, '
    NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $(c["bench"]) == "peak" { peak[$(c["isa"])] = $(c["gflops_median"]) }
    $(c["bench"]) == "triad" && $(c["label"]) != "sweep" {
      col = ($(c["label"]) == "L1") ? "gib_per_s_median" : "gib_per_s_total_median"   # no WA in L1
      bw[$(c["label"])] = $(c[col]) * 1.073741824   # GiB/s -> GB/s
    }
    END {
      print "roof,ai,gflops"
      P = peak["avx2_fma_f32"] + 0
      lo = 0.01; hi = 100
      n = split("L1 L2 L3 DRAM", order, " ")
      for (k = 1; k <= n; k++) {
        L = order[k]; if (!(L in bw) || P <= 0) continue
        B = bw[L]; r = P / B
        printf "%s,%.6g,%.6g\n", L, lo, B * lo
        if (r > lo && r < hi) printf "%s,%.6g,%.6g\n", L, r, P
        printf "%s,%.6g,%.6g\n", L, hi, (B * hi < P ? B * hi : P)
      }
      m = split("avx2_fma_f32 sse_f32 scalar_f32", pk, " ")
      for (k = 1; k <= m; k++) if ((pk[k] in peak) && peak[pk[k]] > 0) {
        printf "peak_%s,%.6g,%.6g\n", pk[k], lo, peak[pk[k]]
        printf "peak_%s,%.6g,%.6g\n", pk[k], hi, peak[pk[k]]
      }
    }' "$P/ceilings.csv" > "$P/roofline_roofs.csv"
  echo "roofline: $P/ceilings_peak.csv $P/ceilings_bw.csv $P/roofline_roofs.csv"
fi
