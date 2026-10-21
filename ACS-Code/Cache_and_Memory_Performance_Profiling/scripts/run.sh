#!/usr/bin/env bash
# run.sh — experiment driver for Project 2 (Cache & Memory Performance Profiling).
#
#   scripts/run.sh <experiment> [<experiment> ...]   any of (README "Required experiments"):
#       zero_queue pattern rw_mix intensity working_set cache_miss tlb pitfall mlc
#   scripts/run.sh all                                every experiment, in that order
#
# Each experiment sweeps its knobs by invoking build/{mem_latency,mem_bandwidth,
# mem_loaded,kernel_miss}, concatenating per-repetition raw rows into
#   data/raw/<experiment>/<timestamp>/raw*.csv
# next to a provenance bundle for that run:
#   env.txt        collect_env.sh snapshot (CPU, governor, turbo, SMT, THP, ...)
#   build.txt      git commit + dirty state, compiler version, CFLAGS, THP/perf settings
#   commands.txt   every benchmark command line, in order
#   validate.txt   output of scripts/validate.sh, run just before the experiment
# then reduces them with tools/summarize (median + IQR per configuration) into
#   data/processed/<name>.csv
# and runs scripts/derive.py, which computes the derived quantities quoted in the
# report (per-level plateaus, knee, Little's Law, AMAT fit) into
#   data/processed/{summary,zero_queue_table,littles_law,knee,amat_fit}.csv
# scripts/sync_data.sh (in ACS-Code) copies data/processed/*.csv into ACS-Latex.
#
# Pinning: single-threaded runs use CPU_PIN (a physical core, not CPU 0). Multi-
# threaded runs place one thread per physical core; the loaded-latency probe of
# mem_loaded runs on CPU_PIN and its load generators on GEN_CPUS (all other
# physical cores). Logical CPUs 0..9 are the ten physical cores of the i9-10900F
# (their SMT siblings are 10..19).
#
# Environment knobs: CPU_PIN (2), MAXT (10 physical cores), REPS (8),
# SEED, VALIDATE (1 = run validate.sh before each experiment).
# Smoke test (NOT for real data):  QUICK=1 DATA=/tmp/p2smoke scripts/run.sh all
# trims every sweep to a few points, 2 reps and 1/10 of the timed interval.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"
SUMMARIZE="$CODE_ROOT/build/tools/summarize"
LAT="$ROOT/build/mem_latency"
BW="$ROOT/build/mem_bandwidth"
LOADED="$ROOT/build/mem_loaded"
KM="$ROOT/build/kernel_miss"
DATA="${DATA:-$ROOT/data}"   # override only for smoke tests (QUICK=1)
PROC="$DATA/processed"

CPU_PIN="${CPU_PIN:-2}"      # one physical core for single-threaded runs / the probe
MAXT="${MAXT:-10}"           # physical cores (logical CPUs 0..MAXT-1)
REPS="${REPS:-8}"
SEED="${SEED:-20260312}"
VALIDATE="${VALIDATE:-1}"
TS="$(date +%Y%m%d-%H%M%S)"

MS_DIV=1
if [ "${QUICK:-0}" = 1 ]; then
  REPS=2; MS_DIV=10; VALIDATE=0
  [ "$DATA" != "$ROOT/data" ] || { echo "QUICK=1 needs DATA=<scratch dir>" >&2; exit 2; }
fi
ms() { echo $(( $1 / MS_DIV > 2 ? $1 / MS_DIV : 2 )); }

# generator CPUs for mem_loaded: every physical core except the probe's
GEN_CPUS="$(seq 0 $((MAXT - 1)) | grep -vx "$CPU_PIN" | paste -sd, -)"
NGEN=$((MAXT - 1))

need() {
  for b in "$LAT" "$BW" "$LOADED" "$KM" "$SUMMARIZE"; do
    [ -x "$b" ] || { echo "missing $b; run 'make' here and 'make tools' in ACS-Code" >&2; exit 1; }
  done
  command -v python3 >/dev/null || { echo "python3 is required for scripts/derive.py" >&2; exit 1; }
}

start_experiment() {
  local exp="$1"
  RAWDIR="$DATA/raw/$exp/$TS"; mkdir -p "$RAWDIR"
  RAW="$RAWDIR/raw.csv"; : > "$RAW"
  echo "[$exp] -> $RAWDIR"
  "$CODE_ROOT/scripts/collect_env.sh" > "$RAWDIR/env.txt" 2>/dev/null || true
  {
    echo "experiment: $exp"
    echo "timestamp:  $TS"
    echo "git commit: $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "git dirty:  $(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l) changed path(s)"
    echo "compiler:   $(${CC:-cc} --version 2>/dev/null | head -1)"
    echo "CFLAGS:     $(make -s -C "$ROOT" print-cflags 2>/dev/null)"
    echo "CPU_PIN=$CPU_PIN GEN_CPUS=$GEN_CPUS MAXT=$MAXT REPS=$REPS SEED=$SEED"
    echo "THP enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
    echo "THP defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)"
    echo "perf_event_paranoid: $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)"
    echo "online CPUs: $(cat /sys/devices/system/cpu/online 2>/dev/null)"
  } > "$RAWDIR/build.txt"
  : > "$RAWDIR/commands.txt"
  if [ "$VALIDATE" = 1 ]; then
    echo "[$exp] validate.sh -> $RAWDIR/validate.txt"
    "$ROOT/scripts/validate.sh" > "$RAWDIR/validate.txt" 2>&1 \
      || echo "[$exp] WARNING: validate.sh reported failures (see validate.txt)" >&2
  fi
}

# run <raw-file> <cmd...>: log the command, append its rows (header only once)
run() {
  local out="$1"; shift
  echo "$*" >> "$RAWDIR/commands.txt"
  if [ -s "$out" ]; then "$@" >> "$out"; else "$@" --header >> "$out"; fi
}

summ() { "$SUMMARIZE" "$@"; }
derive() { python3 "$ROOT/scripts/derive.py" "$PROC"; }

# Working-set sizes (bytes) crossing L1 (32 KiB) / L2 (256 KiB) / L3 (20 MiB) / DRAM.
LAT_SIZES=(8192 16384 24576 32768 49152 65536 98304 131072 196608 262144 393216 524288 \
           1048576 2097152 4194304 8388608 12582912 16777216 25165824 33554432 \
           67108864 134217728 268435456 536870912)
# zero_queue: sizes inside each level's plateau window (see derive.py) + DRAM
ZQ_SIZES=(8192 16384 24576 65536 98304 131072 196608 524288 1048576 2097152 4194304 \
          8388608 12582912 134217728 268435456 536870912)
ZQ_HUGE=(134217728 268435456 536870912)
ACCESS_SIZES=(64 128 256 512 1024 4096)
STRIDES=(8 64 256 1024)
DELAYS=(8 16 32 64 128 256 512 1024 2048)
CHAINS=(1 2 4 6 8 10 12 16 20 24 32)
SAXPY_EXP=($(seq 8 24))
TLB_EXP=(18 19 20 21 22 23 24)
TLB_PAGES=(16 32 48 64 96 128 192 256 384 512 768 1024 1536 2048 3072 4096 8192 16384 32768 65536)
PITFALL_SIZES=(16384 131072 1048576 8388608 67108864 268435456 536870912)
if [ "${QUICK:-0}" = 1 ]; then
  LAT_SIZES=(16384 131072 4194304 134217728); ZQ_SIZES=(16384 131072 4194304 134217728)
  ZQ_HUGE=(134217728); ACCESS_SIZES=(64 1024); STRIDES=(8 64); DELAYS=(256); CHAINS=(1 8)
  SAXPY_EXP=(10 16 20 22 23 24); TLB_EXP=(20); TLB_PAGES=(64 4096); PITFALL_SIZES=(16384 134217728)
fi

# ----------------------------------------------------------------- zero_queue
exp_zero_queue() {
  start_experiment zero_queue
  local b
  # primary method: LCG Sattolo ring, CLOCK_MONOTONIC_RAW, 4 KiB pages
  for b in "${ZQ_SIZES[@]}"; do
    run "$RAW" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" --bytes "$b" \
        --pattern random --pages 4k --gen lcg --timer clock --experiment zero_queue
  done
  # substitute cross-check for Intel MLC: independently generated ring (xorshift64*),
  # TSC timing (rdtscp), different seed
  for b in "${ZQ_SIZES[@]}"; do
    run "$RAW" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed $((SEED + 1)) --bytes "$b" \
        --pattern random --pages 4k --gen xorshift --timer tsc --experiment zero_queue
  done
  # DRAM latency without the page-walk component (2 MiB pages)
  for b in "${ZQ_HUGE[@]}"; do
    run "$RAW" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" --bytes "$b" \
        --pattern random --pages huge --gen lcg --timer clock --experiment zero_queue
  done
  summ --in "$RAW" --out "$PROC/zero_queue.csv" --group bytes,pattern,pages,gen,timer \
       --stat ns_per_access,cycles_per_access
}

# ----------------------------------------------------------------- working_set
exp_working_set() {
  start_experiment working_set
  local b cfg p pg
  for cfg in "random 4k" "sequential 4k" "random huge"; do
    read -r p pg <<< "$cfg"
    for b in "${LAT_SIZES[@]}"; do
      run "$RAW" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" --bytes "$b" \
          --pattern "$p" --pages "$pg" --counters --experiment working_set
    done
  done
  summ --in "$RAW" --out "$PROC/working_set.csv" --group bytes,pattern,pages \
       --stat ns_per_access,cycles_per_access,ctr_l1d_miss_pa,ctr_llc_ref_pa,ctr_llc_miss_pa,ctr_dtlb_miss_pa,ctr_cover
}

# ----------------------------------------------------------------- pattern
exp_pattern() {
  start_experiment pattern
  local RAWL="$RAWDIR/raw_latency.csv" RAWB="$RAWDIR/raw_bandwidth.csv" a p s
  : > "$RAWL"; : > "$RAWB"
  # (1) access-size granularity, DRAM-resident 256 MiB, 1 thread:
  #     latency of one dependent B-byte access, and streaming bandwidth of B-byte blocks
  for p in sequential random; do
    for a in "${ACCESS_SIZES[@]}"; do
      run "$RAWL" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 60) --seed "$SEED" \
          --bytes 268435456 --access "$a" --pattern "$p" --pages 4k --experiment pattern
      run "$RAWB" "$BW" --cpu0 "$CPU_PIN" --threads 1 --reps "$REPS" --min-ms $(ms 120) --seed "$SEED" \
          --kernel read --bytes 268435456 --access "$a" --pattern "$p" --pages 4k --experiment pattern
    done
  done
  # (2) secondary: byte stride with one 8 B element used per stride (scalar FP reads)
  for p in sequential random; do
    for s in "${STRIDES[@]}"; do
      run "$RAWB" "$BW" --cpu0 "$CPU_PIN" --threads 1 --reps "$REPS" --min-ms $(ms 120) --seed "$SEED" \
          --kernel read --bytes 268435456 --strideb "$s" --pattern "$p" --pages 4k --experiment pattern
    done
  done
  rm -f "$RAW"
  summ --in "$RAWL" --out "$PROC/pattern_lat.csv" --group pattern,access,pages --stat ns_per_access,gib_s
  summ --in "$RAWB" --out "$PROC/pattern_bw.csv" --group kernel,pattern,access,strideb --stat gib_s,ns_per_elem
}

# ----------------------------------------------------------------- rw_mix
exp_rw_mix() {
  start_experiment rw_mix
  local RAWR="$RAWDIR/raw_reference.csv" r t k
  : > "$RAWR"
  # Line-granular read/write mixes (R of every 10 lines read, 10-R written) driven by
  # T generator cores while the probe on CPU_PIN measures loaded latency.
  for t in 1 "$NGEN"; do
    for r in 10 7 5 0; do
      run "$RAW" "$LOADED" --kernel rwmix --reads "$r" --threads "$t" --cpus "$GEN_CPUS" \
          --probe-cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k \
          --experiment rw_mix
    done
  done
  # unloaded probe in the same setup (T = 0)
  run "$RAW" "$LOADED" --kernel rwmix --reads 10 --threads 0 --probe-cpu "$CPU_PIN" \
      --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k --experiment rw_mix
  # copy / triad as named-kernel references (all cores, no probe)
  for k in copy triad; do
    run "$RAWR" "$BW" --cpu0 0 --threads "$MAXT" --reps "$REPS" --min-ms $(ms 120) --seed "$SEED" \
        --kernel "$k" --bytes $((MAXT * 134217728)) --pages 4k --experiment rw_mix
  done
  summ --in "$RAW" --out "$PROC/rw_mix.csv" --group kernel,reads10,threads \
       --stat total_gib_s,traffic_gib_s,gen_gib_s,probe_ns,little_l
  summ --in "$RAWR" --out "$PROC/rw_mix_ref.csv" --group kernel,threads --stat gib_s,ns_per_elem
}

# ----------------------------------------------------------------- intensity
exp_intensity() {
  start_experiment intensity
  local RAWM="$RAWDIR/raw_mlp.csv" t d k
  : > "$RAWM"
  # (1) loaded latency: T = 0..NGEN streaming-read generators + concurrent latency probe
  for t in $(seq 0 "$NGEN"); do
    run "$RAW" "$LOADED" --kernel stream --threads "$t" --cpus "$GEN_CPUS" --probe-cpu "$CPU_PIN" \
        --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k --experiment intensity
  done
  # (2) finer intensity steps: all generators, throttled by an injection delay per line
  for d in "${DELAYS[@]}"; do
    run "$RAW" "$LOADED" --kernel stream --threads "$NGEN" --cpus "$GEN_CPUS" --probe-cpu "$CPU_PIN" \
        --delay "$d" --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k --experiment intensity
  done
  # (3) known concurrency: k independent random chases per thread (N = T*k outstanding)
  for k in "${CHAINS[@]}"; do
    run "$RAWM" "$LOADED" --kernel chase --chains "$k" --threads 1 --cpus "$GEN_CPUS" \
        --probe-cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k --experiment intensity
  done
  for t in $(seq 2 "$NGEN"); do
    run "$RAWM" "$LOADED" --kernel chase --chains 8 --threads "$t" --cpus "$GEN_CPUS" \
        --probe-cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 200) --seed "$SEED" --pages 4k --experiment intensity
  done
  summ --in "$RAW" --out "$PROC/intensity_loaded.csv" --group kernel,threads,delay \
       --stat total_gib_s,probe_ns,probe_cycles,little_l,gen_gib_s
  summ --in "$RAWM" --out "$PROC/intensity_mlp.csv" --group kernel,threads,chains \
       --stat gen_gib_s,gen_lat_ns,little_l,probe_ns,total_gib_s
}

# ----------------------------------------------------------------- cache_miss
exp_cache_miss() {
  start_experiment cache_miss
  # SAXPY footprint sweep, sequential vs random order, with user-space counters.
  local e p
  for p in sequential random; do
    for e in "${SAXPY_EXP[@]}"; do
      run "$RAW" "$KM" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" \
          --kernel saxpy --n $((1 << e)) --pattern "$p" --pages 4k --counters --experiment cache_miss
    done
  done
  summ --in "$RAW" --out "$PROC/cache_miss_ctr.csv" --group n,pattern,pages \
       --stat ns_per_elem,ctr_l1d_miss_pe,ctr_llc_ref_pe,ctr_llc_miss_pe,ctr_dtlb_miss_pe,ctr_cycles_pe,ctr_instr_pe,ctr_cover
}

# ----------------------------------------------------------------- tlb
exp_tlb() {
  start_experiment tlb
  local RAWS="$RAWDIR/raw_saxpy.csv" n pg e
  : > "$RAWS"
  # (1) page-stride pointer chase: one node per 4 KiB page (stride 4096+64), so the
  #     number of pages touched sweeps across the L1 dTLB (64) and STLB (1536) reach
  #     while the cache footprint stays N lines; 4 KiB vs 2 MiB pages isolates the TLB.
  for pg in 4k huge; do
    for n in "${TLB_PAGES[@]}"; do
      run "$RAW" "$LAT" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" \
          --bytes $((n * 4160)) --stride 4160 --pattern random --pages "$pg" --counters --experiment tlb
    done
  done
  # (2) random SAXPY over large footprints, 4 KiB vs 2 MiB pages
  for pg in 4k huge; do
    for e in "${TLB_EXP[@]}"; do
      run "$RAWS" "$KM" --cpu "$CPU_PIN" --reps "$REPS" --min-ms $(ms 40) --seed "$SEED" \
          --kernel saxpy --n $((1 << e)) --pattern random --pages "$pg" --counters --experiment tlb
    done
  done
  summ --in "$RAW" --out "$PROC/tlb_chase.csv" --group nodes,pages \
       --stat ns_per_access,cycles_per_access,ctr_dtlb_miss_pa,ctr_l1d_miss_pa,ctr_llc_miss_pa,ctr_cover
  summ --in "$RAWS" --out "$PROC/tlb_saxpy.csv" --group n,pages,pattern \
       --stat ns_per_elem,ctr_dtlb_miss_pe,ctr_llc_miss_pe,ctr_cover
  # huge pages actually granted per configuration (AnonHugePages, KiB)
  awk -F, 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next}
           {print $h["pages"]","$h["nodes"]","$h["anon_thp_kib"]}' "$RAW" | sort -u > "$RAWDIR/anon_thp.txt"
}

# ----------------------------------------------------------------- pitfall
exp_pitfall() {
  start_experiment pitfall
  # Pitfall: single-thread "bandwidth" across working-set sizes. A tiny (L1/L2-
  # resident) set reports far more than DRAM can deliver; calling that "DRAM
  # bandwidth" is the accidental-cache-reuse mistake.
  local b
  for b in "${PITFALL_SIZES[@]}"; do
    run "$RAW" "$BW" --cpu0 "$CPU_PIN" --threads 1 --reps "$REPS" --min-ms $(ms 100) --seed "$SEED" \
        --kernel read --bytes "$b" --pages 4k --experiment pitfall
  done
  summ --in "$RAW" --out "$PROC/pitfall.csv" --group wss_bytes,threads --stat gib_s,ns_per_elem
}

# ----------------------------------------------------------------- mlc
exp_mlc() {
  local MLC_BIN="${MLC:-$(command -v mlc || true)}"
  RAWDIR="$DATA/raw/mlc/$TS"; mkdir -p "$RAWDIR"
  if [ -z "$MLC_BIN" ] || [ ! -x "$MLC_BIN" ]; then
    {
      echo "Intel MLC not installed on this host ($(hostname), $(date '+%F %T %Z'))."
      echo "'command -v mlc' found nothing and \$MLC was not set; no MLC cross-check was run."
      echo "Substitute cross-checks (labelled as such in the report):"
      echo "  zero_queue: second ring generator (xorshift64*) + TSC timing   -> zero_queue.csv gen=xorshift"
      echo "  intensity : mem_loaded T=0 probe (pointer ring, separate code) -> intensity_loaded.csv threads=0"
    } | tee "$RAWDIR/mlc_status.txt" >&2
    echo "[mlc] SKIPPED: Intel MLC not installed (recorded in $RAWDIR/mlc_status.txt)" >&2
    return 0
  fi
  echo "[mlc] -> $RAWDIR ($MLC_BIN)"
  "$CODE_ROOT/scripts/collect_env.sh" > "$RAWDIR/env.txt" 2>/dev/null || true
  "$MLC_BIN" --version        > "$RAWDIR/mlc_version.txt" 2>&1 || true
  "$MLC_BIN" --idle_latency   > "$RAWDIR/idle_latency.txt" 2>&1 || true
  "$MLC_BIN" --loaded_latency > "$RAWDIR/loaded_latency.txt" 2>&1 || true
  "$MLC_BIN" --max_bandwidth  > "$RAWDIR/max_bandwidth.txt" 2>&1 || true
}

ALL_EXPERIMENTS=(zero_queue pattern rw_mix intensity working_set cache_miss tlb pitfall mlc)

usage() {
  echo "usage: $0 {$(IFS='|'; echo "${ALL_EXPERIMENTS[*]}")|all} ..." >&2
}

run_one() {
  case "$1" in
    zero_queue)  exp_zero_queue ;;
    pattern)     exp_pattern ;;
    rw_mix)      exp_rw_mix ;;
    intensity)   exp_intensity ;;
    working_set) exp_working_set ;;
    cache_miss)  exp_cache_miss ;;
    tlb)         exp_tlb ;;
    pitfall)     exp_pitfall ;;
    mlc)         exp_mlc ;;
    *) echo "unknown experiment: $1" >&2; usage; exit 2 ;;
  esac
  derive
  echo "done: $1"
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 2; }
  local e x
  for e in "$@"; do        # reject typos before spending minutes on earlier experiments
    case " ${ALL_EXPERIMENTS[*]} all " in *" $e "*) ;; *) echo "unknown experiment: $e" >&2; usage; exit 2 ;; esac
  done
  need
  mkdir -p "$PROC"
  for e in "$@"; do
    if [ "$e" = all ]; then for x in "${ALL_EXPERIMENTS[@]}"; do run_one "$x"; done
    else run_one "$e"; fi
  done
}
main "$@"
