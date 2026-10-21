#!/usr/bin/env bash
# run.sh — experiment driver for Project 1 (SIMD Advantage Profiling).
#
#   scripts/run.sh <experiment>   one of: ceilings baseline locality alignment stride dtype negative
#   scripts/run.sh derive         re-derive roofline/table CSVs from processed data (no measuring;
#                                 alias: roofline) via scripts/roofline.sh and scripts/tables.sh
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
#
# Hardware counters: if `simd_bench --counters-probe` can open a user-space
# cycle counter (perf_event_open; works unprivileged with perf_event_paranoid
# <= 2), `locality` also records cycles / LLC misses / L1D misses per element
# into data/processed/locality_counters.csv and `ceilings` records the
# effective clock. Otherwise those outputs are simply skipped. COUNTERS=0
# disables them.
#
# Speedup error bars: scripts/speedup_iqr.awk appends speedup_q25/_q75 (the
# speedup range implied by the variant's and scalar's IQRs) to every processed
# CSV that has speedup_vs_scalar.
set -euo pipefail

cd "$(dirname "$0")/.."                      # project root (SIMD_Advantage_Profiling)
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"                   # ACS-Code
BIN() { echo "$ROOT/build/$1/simd_bench"; }
SUMMARIZE="$CODE_ROOT/build/tools/summarize"
CEIL="$ROOT/build/ceilings/ceilings"

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
  [ -x "$CEIL" ] || { echo "missing $CEIL; run 'make' first" >&2; exit 1; }
  [ -x "$SUMMARIZE" ] || { echo "missing $SUMMARIZE; run 'make tools' in ACS-Code" >&2; exit 1; }
}

HAVE_COUNTERS=0
probe_counters() {
  if [ "${COUNTERS:-1}" != 0 ] && "$(BIN native)" --counters-probe >/dev/null 2>&1; then
    HAVE_COUNTERS=1
  fi
  echo "hardware counters: $([ "$HAVE_COUNTERS" = 1 ] && echo available || echo unavailable)"
}

# speedup_iqr <processed.csv>: append speedup_q25/_q75 in place
speedup_iqr() {
  local f="$1"
  awk -f "$ROOT/scripts/speedup_iqr.awk" "$f" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# run_ceil <rawfile> <args...>: one ceilings measurement
run_ceil() {
  local raw="$1"; shift
  local hdr=""
  [ -s "$raw" ] || hdr="--header"
  "$CEIL" --cpu "$CPU_PIN" --reps "$REPS" --min-ms "$MINMS" $hdr "$@" >> "$raw"
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
  speedup_iqr "$ROOT/data/processed/baseline.csv"
  "$ROOT/scripts/roofline.sh"
}

# Machine ceilings for the roofline, independent of the studied kernels:
# register-only FMA/mul+add peak per ISA, and STREAM-style read/copy/triad
# bandwidth at one footprint inside each cache level plus a fine footprint sweep.
exp_ceilings() {
  start_experiment ceilings
  local isa b
  for isa in scalar_f32 scalar_fma_f32 sse_f32 sse_f64 avx2_fma_f32 avx2_fma_f64; do
    run_ceil "$RAW" --experiment ceilings --bench peak --isa "$isa" --label peak
  done
  # total footprint per level (L1d 32 KiB, L2 256 KiB, L3 20 MiB shared, then DRAM)
  local levels=("L1:16384" "L2:131072" "L3:8388608" "DRAM:536870912")
  local lv
  for lv in "${levels[@]}"; do
    for b in read copy triad; do
      run_ceil "$RAW" --experiment ceilings --bench "$b" --bytes "${lv#*:}" --label "${lv%%:*}"
    done
  done
  # footprint sweep 4 KiB .. 512 MiB (powers of two and midpoints)
  local e
  for e in $(seq 12 29); do
    local bytes=$((1 << e))
    for b in read copy triad; do
      run_ceil "$RAW" --experiment ceilings --bench "$b" --bytes "$bytes" --label sweep
      if [ "$e" -lt 29 ]; then
        run_ceil "$RAW" --experiment ceilings --bench "$b" --bytes $((bytes + bytes / 2)) --label sweep
      fi
    done
  done
  local stats="gflops,gib_per_s,gib_per_s_total"
  [ "$HAVE_COUNTERS" = 1 ] && stats="$stats,ghz,flops_per_cycle,bytes_per_cycle"
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/ceilings.csv" \
    --group bench,isa,label,bytes --stat "$stats"
  "$ROOT/scripts/roofline.sh"
  "$ROOT/scripts/tables.sh"
}

exp_locality() {
  start_experiment locality
  local ctr=()
  [ "$HAVE_COUNTERS" = 1 ] && ctr=(--counters)
  local e
  for e in $(seq 10 25); do
    local n=$((1 << e))
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment locality --kernel saxpy --dtype f32 --n "$n" "${ctr[@]}"
    done
    # a few intermediate (non-power-of-two) points to resolve the knees
    local nmid=$(( n + n/2 ))
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment locality --kernel saxpy --dtype f32 --n "$nmid" "${ctr[@]}"
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/locality.csv" \
    --group n,variant --stat ns_per_elem,elems_per_s --speedup
  speedup_iqr "$ROOT/data/processed/locality.csv"
  if [ "$HAVE_COUNTERS" = 1 ]; then
    "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/locality_counters.csv" \
      --group n,variant --stat cycles_per_elem,llc_miss_per_elem,l1d_miss_per_elem,ipc,ghz
  fi
  "$ROOT/scripts/tables.sh"
}

exp_alignment() {
  start_experiment alignment
  # Offset sweep (offsets are multiples of 4 bytes so float32 access stays
  # naturally aligned at the element level) at an L1-resident N, where the
  # prologue/split-load cost is exposed, and at a DRAM-resident N (128 MiB),
  # where it should hide behind memory bandwidth.
  local n0 off v n
  for n0 in 4096 16777216; do
    for off in 0 4 8 12 16 20 24 28 32 36 60; do
      for v in "${VARIANTS[@]}"; do
        run_one "$v" "$RAW" --experiment alignment --kernel saxpy --dtype f32 --n "$n0" --offset "$off"
      done
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/alignment.csv" \
    --group offset,n,variant --stat ns_per_elem,elems_per_s
  # Tail-length sweep at offset 0, separate raw/processed file: every N from 8
  # to 72 (the remainder mod 4 and mod 8 is visible in time per call), plus N
  # stepping across an 8-lane boundary near 4096.
  local RAWT="$RAWDIR/raw_tail.csv"
  : > "$RAWT"
  for n in $(seq 8 72) 4088 4089 4090 4092 4096 4097 4100 4104 4112 4120 4128; do
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAWT" --experiment alignment_tail --kernel saxpy --dtype f32 --n "$n" --offset 0
    done
  done
  "$SUMMARIZE" --in "$RAWT" --out "$ROOT/data/processed/alignment_tail.csv" \
    --group n,variant --stat ns_per_elem,elems_per_s
}

exp_stride() {
  start_experiment stride
  # Cache-resident and DRAM-resident working sets.
  for n in 32768 4194304; do
    for s in 1 2 4 8 16; do
      for v in "${VARIANTS[@]}"; do
        run_one "$v" "$RAW" --experiment stride --access stride --stride "$s" --n "$n"
      done
    done
    # unit-stride and gather reference points at the same N
    for v in "${VARIANTS[@]}"; do
      run_one "$v" "$RAW" --experiment stride --access unit --n "$n"
      run_one "$v" "$RAW" --experiment stride --access gather --n "$n"
    done
    # explicit AVX2 hardware gather (vgatherdps), only in the native build
    run_one native "$RAW" --experiment stride --access gather_avx2 --n "$n"
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/stride.csv" \
    --group stride,access,variant,n --stat ns_per_elem,elems_per_s
  "$ROOT/scripts/tables.sh"
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
  speedup_iqr "$ROOT/data/processed/dtype.csv"
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
  speedup_iqr "$ROOT/data/processed/negative.csv"
}

main() {
  local what="${1:-all}"
  mkdir -p "$ROOT/data/processed"
  if [ "$what" = derive ] || [ "$what" = roofline ]; then
    "$ROOT/scripts/roofline.sh"; "$ROOT/scripts/tables.sh"; echo "done: $what"; return
  fi
  need_binaries
  probe_counters
  case "$what" in
    ceilings)  exp_ceilings ;;
    baseline)  exp_baseline ;;
    locality)  exp_locality ;;
    alignment) exp_alignment ;;
    stride)    exp_stride ;;
    dtype)     exp_dtype ;;
    negative)  exp_negative ;;
    all)       exp_ceilings; exp_baseline; exp_locality; exp_alignment; exp_stride; exp_dtype; exp_negative ;;
    *) echo "unknown experiment: $what" >&2
       echo "usage: $0 {ceilings|baseline|locality|alignment|stride|dtype|negative|derive|all}" >&2
       exit 2 ;;
  esac
  echo "done: $what"
}
main "$@"
