#!/usr/bin/env bash
# run.sh — experiment driver for Project 1 (SIMD Advantage Profiling).
#
#   scripts/run.sh <experiment>   one of: baseline locality alignment stride dtype negative
#   scripts/run.sh all            every experiment
#
# Each experiment sweeps its knobs by invoking build/<variant>/simd_bench many
# times, concatenating the per-repetition raw rows into
#   data/raw/<experiment>/<timestamp>/raw.csv
# (alongside a snapshot of the measurement environment), then reduces them with
# tools/summarize into
#   data/processed/<experiment>.csv
# which the ACS-Latex figures read directly.
#
# Runs are single-threaded and pinned to one physical core (CPU_PIN). Edit
# CPU_PIN for the test machine; collect_env.sh records which core was used.
set -euo pipefail

cd "$(dirname "$0")/.."                      # project root (SIMD_Advantage_Profiling)
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"                   # ACS-Code
BIN() { echo "$ROOT/build/$1/simd_bench"; }
SUMMARIZE="$CODE_ROOT/build/tools/summarize"

CPU_PIN="${CPU_PIN:-2}"                        # physical P-core, not CPU 0
REPS="${REPS:-12}"
MINMS="${MINMS:-25}"
SEED="${SEED:-20260312}"
VARIANTS=(scalar autovec native)

TS="$(date +%Y%m%d-%H%M%S)"

need_binaries() {
  for v in "${VARIANTS[@]}"; do
    [ -x "$(BIN "$v")" ] || { echo "missing $(BIN "$v"); run 'make' first" >&2; exit 1; }
  done
  [ -x "$SUMMARIZE" ] || { echo "missing $SUMMARIZE; run 'make tools' in ACS-Code" >&2; exit 1; }
}

# run_one <variant> <rawfile> <args...>
run_one() {
  local variant="$1" raw="$2"; shift 2
  local hdr=""
  [ -s "$raw" ] || hdr="--header"
  "$(BIN "$variant")" --cpu "$CPU_PIN" --reps "$REPS" --min-ms "$MINMS" --seed "$SEED" \
      $hdr "$@" >> "$raw"
}

start_experiment() {   # <name> -> sets RAWDIR, RAW, echoes banner
  local exp="$1"
  RAWDIR="$ROOT/data/raw/$exp/$TS"
  mkdir -p "$RAWDIR"
  RAW="$RAWDIR/raw.csv"
  : > "$RAW"
  echo "[$exp] -> $RAW"
  # snapshot the environment next to the raw data
  "$CODE_ROOT/scripts/collect_env.sh" > "$RAWDIR/env.txt" 2>/dev/null || true
}

# ------------------------------------------------------------------ experiments
exp_baseline() {
  start_experiment baseline
  local kernels=(saxpy dot mul stencil)
  local e
  for e in $(seq 8 25); do
    local n=$((1 << e))
    for k in "${kernels[@]}"; do
      for v in "${VARIANTS[@]}"; do
        run_one "$v" "$RAW" --experiment baseline --kernel "$k" --dtype f32 --n "$n"
      done
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/baseline.csv" \
    --group n,kernel,variant --stat elems_per_s,ns_per_elem,gflops --speedup
}

exp_locality() {
  start_experiment locality
  local e
  for e in $(seq 10 25); do
    local n=$((1 << e))
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment locality --kernel saxpy --dtype f32 --n "$n"
    done
    # a few intermediate (non-power-of-two) points to resolve the knees
    local nmid=$(( n + n/2 ))
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment locality --kernel saxpy --dtype f32 --n "$nmid"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/locality.csv" \
    --group n,variant --stat ns_per_elem,elems_per_s --speedup
}

exp_alignment() {
  start_experiment alignment
  # Offset sweep at a fixed cache-resident N (offsets are multiples of 4 bytes
  # so float32 access stays naturally aligned at the element level).
  local n0=4096
  for off in 0 4 8 12 16 20 24 28 32 36 60; do
    for v in native scalar; do
      run_one "$v" "$RAW" --experiment alignment --kernel saxpy --dtype f32 --n "$n0" --offset "$off"
    done
  done
  # Tail-length sweep at offset 0: N stepping across a vector-width boundary.
  for n in 4088 4089 4090 4092 4096 4097 4100 4104 4112 4120 4128; do
    for v in native scalar; do
      run_one "$v" "$RAW" --experiment alignment --kernel saxpy --dtype f32 --n "$n" --offset 0
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/alignment.csv" \
    --group offset,n,variant --stat ns_per_elem,elems_per_s
}

exp_stride() {
  start_experiment stride
  # Cache-resident and DRAM-resident working sets.
  for n in 32768 4194304; do
    for s in 1 2 4 8 16; do
      for v in scalar native; do
        run_one "$v" "$RAW" --experiment stride --access stride --stride "$s" --n "$n"
      done
    done
    # unit-stride and gather reference points at the same N
    for v in scalar native; do
      run_one "$v" "$RAW" --experiment stride --access unit --n "$n"
      run_one "$v" "$RAW" --experiment stride --access gather --n "$n"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/stride.csv" \
    --group stride,access,variant,n --stat ns_per_elem,elems_per_s
}

exp_dtype() {
  start_experiment dtype
  local e
  for e in 10 12 14 16 18 20 22 24; do
    local n=$((1 << e))
    for k in saxpy mul dot stencil; do
      for dt in f32 f64; do
        for v in "${VARIANTS[@]}"; do
          run_one "$v" "$RAW" --experiment dtype --kernel "$k" --dtype "$dt" --n "$n"
        done
      done
    done
    # int32 elementwise multiply for comparison
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment dtype --kernel mul --dtype i32 --n "$n"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/dtype.csv" \
    --group n,kernel,variant,dtype --stat elems_per_s,gflops --speedup
}

exp_negative() {
  start_experiment negative
  # Memory-bound SAXPY: vectorizes, but DRAM bandwidth caps the gain.
  for e in 10 14 18 22 23 24 25; do
    local n=$((1 << e))
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment negative --kernel saxpy --dtype f32 --n "$n"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/negative.csv" \
    --group n,kernel,variant --stat elems_per_s,ns_per_elem,gflops --speedup
}

main() {
  need_binaries
  mkdir -p "$ROOT/data/processed"
  local what="${1:-all}"
  case "$what" in
    baseline)  exp_baseline ;;
    locality)  exp_locality ;;
    alignment) exp_alignment ;;
    stride)    exp_stride ;;
    dtype)     exp_dtype ;;
    negative)  exp_negative ;;
    all)       exp_baseline; exp_locality; exp_alignment; exp_stride; exp_dtype; exp_negative ;;
    *) echo "unknown experiment: $what" >&2
       echo "usage: $0 {baseline|locality|alignment|stride|dtype|negative|all}" >&2
       exit 2 ;;
  esac
  echo "done: $what"
}
main "$@"
