#!/usr/bin/env bash
# run.sh — experiment driver for Project 2 (Cache & Memory Performance Profiling).
#
#   scripts/run.sh <experiment>   one of:
#       latency granularity rwmix intensity cache_miss tlb pitfall
#   scripts/run.sh all            every experiment
#
# Each experiment sweeps its knobs by invoking build/{mem_latency,mem_bandwidth,
# kernel_miss} many times, concatenating per-repetition raw rows into
#   data/raw/<experiment>/<timestamp>/raw.csv   (+ a snapshot of the environment)
# then reduces them with tools/summarize into
#   data/processed/<experiment>.csv
# which the ACS-Latex figures read directly.
#
# Latency / kernel runs are single-threaded and pinned to one physical core
# (CPU_PIN). The intensity sweep pins thread i to physical core i (0..T-1).
# perf is not installed on the test host, so cache-/TLB-miss experiments report
# runtime and ns/element and attribute behaviour to footprint/page size, not
# counters (see the report's §Limitations).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"
SUMMARIZE="$CODE_ROOT/build/tools/summarize"
LAT="$ROOT/build/mem_latency"
BW="$ROOT/build/mem_bandwidth"
KM="$ROOT/build/kernel_miss"

CPU_PIN="${CPU_PIN:-2}"      # one physical P-core for single-threaded runs
CPU0="${CPU0:-0}"           # first core for the multi-threaded intensity sweep
MAXT="${MAXT:-10}"          # physical cores available for intensity sweep
REPS="${REPS:-8}"
SEED="${SEED:-20260312}"
TS="$(date +%Y%m%d-%H%M%S)"

need() { for b in "$LAT" "$BW" "$KM" "$SUMMARIZE"; do
  [ -x "$b" ] || { echo "missing $b; run 'make' (and 'make tools' in ACS-Code)" >&2; exit 1; }; done; }

start_experiment() {
  local exp="$1"
  RAWDIR="$ROOT/data/raw/$exp/$TS"; mkdir -p "$RAWDIR"
  RAW="$RAWDIR/raw.csv"; : > "$RAW"
  echo "[$exp] -> $RAW"
  "$CODE_ROOT/scripts/collect_env.sh" > "$RAWDIR/env.txt" 2>/dev/null || true
}
hdr() { [ -s "$RAW" ] || echo "--header"; }

# Working-set sizes (bytes) crossing L1 (32 KiB) / L2 (256 KiB) / L3 (20 MiB) / DRAM.
LAT_SIZES=(8192 16384 24576 32768 49152 98304 131072 196608 262144 393216 524288 \
           1048576 2097152 4194304 8388608 12582912 16777216 25165824 33554432 \
           67108864 134217728 268435456 536870912)

exp_latency() {
  start_experiment latency
  local b p
  for p in random sequential; do
    for b in "${LAT_SIZES[@]}"; do
      "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms 40 --seed "$SEED" \
             --bytes "$b" --stride 64 --pattern "$p" --experiment latency $(hdr) >> "$RAW"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/latency.csv" \
    --group bytes,pattern,pages,stride --stat ns_per_access,cycles_per_access
}

exp_granularity() {
  start_experiment granularity
  # Bandwidth vs access granularity (byte stride) and pattern, DRAM-resident.
  local s p
  for p in sequential random; do
    for s in 8 64 256 1024; do
      "$BW" --cpu0 "$CPU_PIN" --threads 1 --reps "$REPS" --min-ms 120 --seed "$SEED" \
            --kernel read --bytes 268435456 --strideb "$s" --pattern "$p" \
            --experiment granularity $(hdr) >> "$RAW"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/granularity.csv" \
    --group strideb,pattern,threads --stat gib_s,ns_per_elem
}

exp_rwmix() {
  start_experiment rwmix
  # Exact read/write mixes via rwmix (reads per 10): 100/0, 70/30, 50/50, 0/100.
  # Run at enough threads to be DRAM-bandwidth bound.
  local r t="${MAXT}"
  for r in 10 7 5 0; do
    "$BW" --cpu0 "$CPU0" --threads "$t" --reps "$REPS" --min-ms 120 --seed "$SEED" \
          --kernel rwmix --reads "$r" --bytes $((t*134217728)) \
          --experiment rwmix $(hdr) >> "$RAW"
  done
  # copy and triad as named-kernel references
  local k
  for k in copy triad; do
    "$BW" --cpu0 "$CPU0" --threads "$t" --reps "$REPS" --min-ms 120 --seed "$SEED" \
          --kernel "$k" --bytes $((t*134217728)) --experiment rwmix $(hdr) >> "$RAW"
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/rwmix.csv" \
    --group kernel,reads10,threads --stat gib_s,ns_per_elem
}

exp_intensity() {
  start_experiment intensity
  # Access-intensity sweep: more threads -> more outstanding requests. Each thread
  # streams its own 128 MiB DRAM-resident chunk, pinned to a distinct physical core.
  local t
  for t in $(seq 1 "$MAXT"); do
    "$BW" --cpu0 "$CPU0" --threads "$t" --reps "$REPS" --min-ms 150 --seed "$SEED" \
          --kernel read --bytes $((t*134217728)) \
          --experiment intensity $(hdr) >> "$RAW"
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/intensity.csv" \
    --group threads --stat gib_s,ns_per_elem
}

exp_cache_miss() {
  start_experiment cache_miss
  # SAXPY footprint sweep, sequential vs random order (perf unavailable -> runtime).
  local e p
  for p in sequential random; do
    for e in 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
      "$KM" --cpu "$CPU_PIN" --reps "$REPS" --min-ms 40 --seed "$SEED" \
            --kernel saxpy --n $((1 << e)) --pattern "$p" --pages 4k \
            --experiment cache_miss $(hdr) >> "$RAW"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/cache_miss.csv" \
    --group n,pattern,pages --stat ns_per_elem,gflops
}

exp_tlb() {
  start_experiment tlb
  # Random SAXPY over large footprints, 4 KiB vs transparent huge pages.
  local e pg
  for pg in 4k huge; do
    for e in 18 20 21 22 23 24; do
      "$KM" --cpu "$CPU_PIN" --reps "$REPS" --min-ms 40 --seed "$SEED" \
            --kernel saxpy --n $((1 << e)) --pattern random --pages "$pg" \
            --experiment tlb $(hdr) >> "$RAW"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/tlb.csv" \
    --group n,pages,pattern --stat ns_per_elem,gflops
}

exp_pitfall() {
  start_experiment pitfall
  # Pitfall: single-thread "bandwidth" across working-set sizes. A tiny (L1/L2-
  # resident) set reports >100 GiB/s; naively calling that "DRAM bandwidth" is the
  # accidental-cache-reuse mistake. The large sizes show the true DRAM rate.
  local b
  for b in 16384 131072 1048576 8388608 67108864 268435456 536870912; do
    "$BW" --cpu0 "$CPU_PIN" --threads 1 --reps "$REPS" --min-ms 100 --seed "$SEED" \
          --kernel read --bytes "$b" --experiment pitfall $(hdr) >> "$RAW"
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/pitfall.csv" \
    --group wss_bytes,threads --stat gib_s,ns_per_elem
}

main() {
  need
  mkdir -p "$ROOT/data/processed"
  case "${1:-all}" in
    latency)     exp_latency ;;
    granularity) exp_granularity ;;
    rwmix)       exp_rwmix ;;
    intensity)   exp_intensity ;;
    cache_miss)  exp_cache_miss ;;
    tlb)         exp_tlb ;;
    pitfall)     exp_pitfall ;;
    all) exp_latency; exp_granularity; exp_rwmix; exp_intensity; exp_cache_miss; exp_tlb; exp_pitfall ;;
    *) echo "unknown experiment: $1" >&2
       echo "usage: $0 {latency|granularity|rwmix|intensity|cache_miss|tlb|pitfall|all}" >&2; exit 2 ;;
  esac
  echo "done: ${1:-all}"
}
main "$@"
