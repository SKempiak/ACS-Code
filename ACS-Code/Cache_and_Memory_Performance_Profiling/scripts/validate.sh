#!/usr/bin/env bash
# validate.sh — correctness / sanity checks for Project 2 (make-style gate).
#
# The memory benchmarks have no "reference output" to diff, so we validate them
# against physical expectations that must hold on any sane cache hierarchy:
#   1. Latency grows monotonically across levels: L1 < L2 < L3 < DRAM.
#   2. Random DRAM latency >> sequential DRAM latency (prefetcher is defeated).
#   3. Single-core bandwidth to an L1-resident set >> bandwidth to a DRAM set.
#   4. Aggregate read bandwidth with many threads > single-thread bandwidth.
#   5. The effective-frequency probe lands in a plausible range (1-6 GHz).
# Exits non-zero if any check fails.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CPU_PIN="${CPU_PIN:-2}"
LAT="$ROOT/build/mem_latency"; BW="$ROOT/build/mem_bandwidth"
for b in "$LAT" "$BW"; do [ -x "$b" ] || { echo "missing $b; run make" >&2; exit 1; }; done
fail=0
# median ns_per_access (col 12) of a short latency run at a given size/pattern
lat() { "$LAT" --cpu "$CPU_PIN" --reps 3 --min-ms 20 --bytes "$1" --pattern "$2" \
          | awk -F, '{s+=$12;n++} END{printf "%.3f", s/n}'; }
bw()  { "$BW" --cpu0 0 --threads "$1" --reps 2 --min-ms 60 --kernel read --bytes "$2" \
          | awk -F, '{s+=$13;n++} END{printf "%.3f", s/n}'; }
ghz() { "$LAT" --cpu "$CPU_PIN" --reps 1 --min-ms 10 --bytes 16384 | awk -F, 'NR==1{print $7; exit}'; }

L1=$(lat 16384 random); L2=$(lat 196608 random); L3=$(lat 8388608 random); DR=$(lat 268435456 random)
DRseq=$(lat 268435456 sequential)
echo "latency ns/access: L1=$L1 L2=$L2 L3=$L3 DRAM=$DR (DRAM seq=$DRseq)"
chk() { awk "BEGIN{exit !($1)}" && echo "  OK: $2" || { echo "  FAIL: $2" >&2; fail=1; }; }
chk "$L1 < $L2" "L1 < L2"
chk "$L2 < $L3" "L2 < L3"
chk "$L3 < $DR" "L3 < DRAM"
chk "$DRseq * 2 < $DR" "sequential DRAM << random DRAM (prefetch works)"

B1=$(bw 1 16384); Bd=$(bw 1 268435456); Bn=$(bw 10 1342177280)
echo "read GiB/s: L1(1t)=$B1 DRAM(1t)=$Bd DRAM(10t)=$Bn"
chk "$B1 > $Bd" "L1 bandwidth > DRAM bandwidth (single core)"
chk "$Bn > $Bd" "10-thread DRAM bandwidth > 1-thread"

G=$(ghz); echo "effective GHz probe: $G"
chk "$G > 1.0 && $G < 6.0" "frequency probe in plausible range"

[ "$fail" -eq 0 ] && echo "all P2 sanity checks passed" || { echo "P2 VALIDATION FAILED" >&2; exit 1; }
