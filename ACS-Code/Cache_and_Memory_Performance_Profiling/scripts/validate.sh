#!/usr/bin/env bash
# validate.sh — correctness / sanity checks for Project 2 (make-style gate, ~15 s).
#
# The memory benchmarks have no "reference output" to diff, so we validate them
# against physical expectations that must hold on any sane cache hierarchy:
#   1. Latency grows monotonically across levels: L1 < L2 < L3 < DRAM.
#   2. Random DRAM latency >> sequential DRAM latency (prefetcher is defeated).
#   3. The two independent latency methods (LCG ring + clock vs xorshift ring +
#      TSC) agree within 15% on DRAM latency (substitute for an MLC cross-check).
#   4. Single-core bandwidth to an L1-resident set >> bandwidth to a DRAM set.
#   5. Aggregate read bandwidth with many threads > single-thread bandwidth.
#   6. mem_loaded: probe latency under 4-core streaming load > unloaded latency.
#   7. The effective-frequency probe lands in a plausible range (1-6 GHz).
# Informational (WARN, not FAIL): perf_event_open counters usable; 2 MiB pages
# actually granted when requested; 4 KiB policy really yields no huge pages.
# Exits non-zero if any check fails. run.sh saves this output per experiment.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CPU_PIN="${CPU_PIN:-2}"
LAT="$ROOT/build/mem_latency"; BW="$ROOT/build/mem_bandwidth"; LOADED="$ROOT/build/mem_loaded"
for b in "$LAT" "$BW" "$LOADED"; do [ -x "$b" ] || { echo "missing $b; run make" >&2; exit 1; }; done
fail=0

# median of column <name> over the CSV on stdin (header line required)
col_median() {
  awk -F, -v c="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i; next} k{print $k}' \
    | sort -g | awk '{v[n++]=$1} END{ if(!n || v[0]=="nan"){print "nan"; exit}
         m=(n%2)?v[(n-1)/2]:(v[n/2-1]+v[n/2])/2; printf "%.4f", m }'
}
lat() { "$LAT" --cpu "$CPU_PIN" --reps 3 --min-ms 20 --bytes "$1" --pattern "$2" --header "${@:3}" \
          | col_median "${COL:-ns_per_access}"; }
bw()  { "$BW" --cpu0 0 --threads "$1" --reps 2 --min-ms 60 --kernel read --bytes "$2" --header \
          | col_median gib_s; }
chk() { awk "BEGIN{exit !($1)}" && echo "  OK: $2" || { echo "  FAIL: $2" >&2; fail=1; }; }
warn() { awk "BEGIN{exit !($1)}" && echo "  OK: $2" || echo "  WARN: $2"; }

echo "validate.sh  $(date '+%F %T %Z')  CPU_PIN=$CPU_PIN"
echo "governor=$(cat /sys/devices/system/cpu/cpu$CPU_PIN/cpufreq/scaling_governor 2>/dev/null)" \
     "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)" \
     "smt=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null)" \
     "online=$(cat /sys/devices/system/cpu/online 2>/dev/null)"

L1=$(lat 16384 random); L2=$(lat 131072 random); L3=$(lat 4194304 random); DR=$(lat 268435456 random)
DRseq=$(lat 268435456 sequential)
DRx=$(lat 268435456 random --gen xorshift --timer tsc --seed 7)
echo "latency ns/access: L1=$L1 L2=$L2 L3=$L3 DRAM=$DR (DRAM seq=$DRseq; xorshift+TSC=$DRx)"
chk "$L1 < $L2" "L1 < L2"
chk "$L2 < $L3" "L2 < L3"
chk "$L3 < $DR" "L3 < DRAM"
chk "$DRseq * 2 < $DR" "sequential DRAM << random DRAM (prefetch works)"
chk "$DRx > 0.85 * $DR && $DRx < 1.15 * $DR" "independent latency method agrees within 15% on DRAM"

B1=$(bw 1 16384); Bd=$(bw 1 268435456); Bn=$(bw 10 1342177280)
echo "read GiB/s: L1(1t)=$B1 DRAM(1t)=$Bd DRAM(10t)=$Bn"
chk "$B1 > $Bd" "L1 bandwidth > DRAM bandwidth (single core)"
chk "$Bn > $Bd" "10-thread DRAM bandwidth > 1-thread"

others="$(seq 0 9 | grep -vx "$CPU_PIN" | head -4 | paste -sd, -)"
P0=$("$LOADED" --threads 0 --probe-cpu "$CPU_PIN" --reps 3 --min-ms 100 --header | col_median probe_ns)
P4=$("$LOADED" --threads 4 --cpus "$others" --probe-cpu "$CPU_PIN" --reps 3 --min-ms 100 --header | col_median probe_ns)
echo "loaded latency ns: unloaded=$P0 under 4 streaming cores=$P4"
chk "$P4 > $P0" "loaded latency > unloaded latency"

G=$("$LAT" --cpu "$CPU_PIN" --reps 1 --min-ms 10 --bytes 16384 --header | col_median ghz)
echo "effective GHz probe: $G"
chk "$G > 1.0 && $G < 6.0" "frequency probe in plausible range"

# informational checks
C=$(COL=ctr_dtlb_miss_pa lat 268435456 random --counters)
echo "dTLB misses/access, 256 MiB random, 4 KiB pages: $C"
warn "\"$C\" != \"nan\"" "perf_event_open user-space counters available"
H=$("$LAT" --cpu "$CPU_PIN" --reps 1 --min-ms 10 --bytes 67108864 --pages huge --header | col_median anon_thp_kib)
H4=$("$LAT" --cpu "$CPU_PIN" --reps 1 --min-ms 10 --bytes 67108864 --pages 4k --header | col_median anon_thp_kib)
echo "AnonHugePages KiB for a 64 MiB buffer: huge=$H 4k=$H4"
warn "$H >= 32768" "2 MiB pages granted when requested"
warn "$H4 == 0" "4 KiB policy yields no huge pages"

[ "$fail" -eq 0 ] && echo "all P2 sanity checks passed" || { echo "P2 VALIDATION FAILED" >&2; exit 1; }
