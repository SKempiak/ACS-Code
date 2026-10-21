#!/usr/bin/env bash
# fio_to_csv.sh — convert one FIO JSON result (fio/job.fio) into the blkbench CSV row.
#
#   fio --output-format=json fio/job.fio | scripts/fio_to_csv.sh [--header] \
#       EXPERIMENT MODE PATTERN BS QD RWMIX REP TEMP_C
#
# Columns (identical to build/blkbench, so both engines feed the same summaries):
#   experiment,mode,pattern,bs,qd,rwmix,rep,ios,secs,iops,mibps,
#   lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,temp_c
#
# Latency is fio's total latency (lat_ns = submission + completion), the quantity
# blkbench measures (submit -> reap); job.fio sets lat_percentiles=1 so its
# percentiles exist. job.fio also sets unified_rw_reporting=mixed, so reads and
# writes arrive combined in a "mixed" section; if that section is absent (older
# fio), read and write are combined here: counts and bandwidth are summed, the
# mean is IO-weighted, and each percentile is the IO-weighted mean of the two
# directions' percentiles (an approximation, flagged in the report).
# MODE/PATTERN/... are passed by run.sh rather than inferred. Requires jq.
set -euo pipefail
hdr=0; [ "${1:-}" = "--header" ] && { hdr=1; shift; }
[ $# -eq 8 ] || { echo "usage: $0 [--header] EXPERIMENT MODE PATTERN BS QD RWMIX REP TEMP_C < fio.json" >&2; exit 2; }
command -v jq >/dev/null || { echo "fio_to_csv: jq required" >&2; exit 2; }

[ "$hdr" = 1 ] && echo "experiment,mode,pattern,bs,qd,rwmix,rep,ios,secs,iops,mibps,lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,temp_c"

jq -r --arg exp "$1" --arg mode "$2" --arg pat "$3" --arg bs "$4" --arg qd "$5" \
      --arg rw "$6" --arg rep "$7" --arg temp "$8" '
  def pc($d; $k): (($d.lat_ns.percentile // $d.clat_ns.percentile // {})[$k] // 0) / 1000.0;
  def bwb($d): ($d.bw_bytes // (($d.bw // 0) * 1024));
  .jobs[0] as $j |
  (if $j.mixed then [$j.mixed] else [$j.read, $j.write] | map(select(. != null and .total_ios > 0)) end) as $ds |
  ($ds | map(.total_ios) | add) as $ios |
  ($ds | map(.runtime) | max / 1000.0) as $secs |
  ($ds | map(.iops) | add) as $iops |
  (($ds | map(bwb(.)) | add) / 1048576.0) as $mibps |
  def wavg(f): ($ds | map((.total_ios / $ios) * f) | add);
  [ $exp, $mode, $pat, $bs, $qd, $rw, $rep, $ios, $secs, $iops, $mibps,
    wavg(.lat_ns.mean / 1000.0),
    wavg(pc(.; "50.000000")), wavg(pc(.; "95.000000")),
    wavg(pc(.; "99.000000")), wavg(pc(.; "99.900000")), $temp ]
  | map(tostring) | join(",")'
