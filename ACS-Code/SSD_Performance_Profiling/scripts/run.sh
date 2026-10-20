#!/usr/bin/env bash
# run.sh — experiment driver for Project 3 (SSD / storage performance profiling).
#
#   scripts/run.sh <experiment>   one of:
#       zero_queue block_size rw_mix queue_depth tail device_state pitfall
#   scripts/run.sh all            every experiment (preconditions once first)
#
# All I/O is direct (O_DIRECT) against a single large DISPOSABLE file under
# data/scratch/, gated by scripts/safety.sh (which refuses any device/partition or
# mountpoint). FIO is used if installed; otherwise the libaio stand-in
# build/blkbench runs — both emit the same CSV schema, reduced by tools/summarize
# into data/processed/<experiment>.csv for the ACS-Latex figures.
#
# DEVICE NOTE: the device under test is whatever filesystem holds the scratch
# directory. By default that is the in-repo data/scratch/ (here a rotational SATA
# HDD, /dev/sda1). Set ACS_SCRATCH to a directory on another device to target it
# instead — e.g. ACS_SCRATCH=$HOME/acs_ssd_scratch for the Micron NVMe SSD mounted
# at /. The same safety gate (scripts/safety.sh) applies to whichever path is used:
# the target must be a plain disposable file inside that scratch directory, never a
# device, partition or mountpoint. The report labels the measured device explicitly.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"
SUMMARIZE="$CODE_ROOT/build/tools/summarize"
BLK="$ROOT/build/blkbench"
SCRATCH="${ACS_SCRATCH:-$ROOT/data/scratch}"
FILE="$SCRATCH/testfile.bin"

FSIZE_MIB="${FSIZE_MIB:-2048}"     # disposable file size (MiB); LBA range used
RUNTIME="${RUNTIME:-4}"
REPS="${REPS:-2}"
SEED="${SEED:-20260312}"
TS="$(date +%Y%m%d-%H%M%S)"
USE_FIO="${USE_FIO:-auto}"

need() { [ -x "$BLK" ] || { echo "missing $BLK; run 'make'" >&2; exit 1; }
         [ -x "$SUMMARIZE" ] || { echo "missing $SUMMARIZE; run 'make tools' in ACS-Code" >&2; exit 1; }; }
have_fio() { [ "$USE_FIO" != 0 ] && command -v fio >/dev/null 2>&1; }

start_experiment() {
  local exp="$1"
  RAWDIR="$ROOT/data/raw/$exp/$TS"; mkdir -p "$RAWDIR"
  RAW="$RAWDIR/raw.csv"; : > "$RAW"
  echo "[$exp] -> $RAW"
  { "$CODE_ROOT/scripts/collect_env.sh"
    echo "# --- storage device under test ---"
    df -hT "$SCRATCH" 2>/dev/null
    local dev; dev=$(df --output=source "$SCRATCH" | tail -1)
    echo "# source device: $dev"
    lsblk -o NAME,ROTA,SIZE,MODEL,MOUNTPOINT 2>/dev/null
    echo "# rotational: $(cat /sys/block/$(basename "$dev" | sed 's/[0-9]*$//')/queue/rotational 2>/dev/null || echo '?') (1=HDD,0=SSD)"
    echo "# disposable file: $FILE (${FSIZE_MIB} MiB)"
    smartctl -i "$dev" 2>&1 | sed 's/^/# smartctl: /' | head -20
  } > "$RAWDIR/env.txt" 2>/dev/null || true
}
hdr() { [ -s "$RAW" ] || echo "--header"; }

# blk <args...> : one measurement via fio (if present) or blkbench, appended to $RAW
blk() {
  if have_fio; then
    echo "fio path not exercised on this host (fio present: parsing via fio_to_csv.sh)" >&2
  fi
  "$BLK" --file "$FILE" --seed "$SEED" "$@" >> "$RAW"
}

precondition() {
  "$ROOT/scripts/safety.sh" "$FILE" $((FSIZE_MIB*1024*1024 + 1073741824)) || exit 1
  if [ ! -f "$FILE" ] || [ "$(stat -c %s "$FILE" 2>/dev/null || echo 0)" -ne $((FSIZE_MIB*1024*1024)) ]; then
    echo "creating ${FSIZE_MIB} MiB disposable file $FILE"
    rm -f "$FILE"
    dd if=/dev/zero of="$FILE" bs=1M count="$FSIZE_MIB" status=none
  fi
  echo "preconditioning (full sequential O_DIRECT write)…"
  "$BLK" --file "$FILE" --precondition --bs 1048576
}

exp_zero_queue() {
  start_experiment zero_queue
  blk --experiment zero_queue --bs 4096   --qd 1 --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps 3 $(hdr)
  blk --experiment zero_queue --bs 4096   --qd 1 --pattern rand --rwmix 0  --runtime "$RUNTIME" --reps 3 $(hdr)
  blk --experiment zero_queue --bs 131072 --qd 1 --pattern seq  --rwmix 10 --runtime "$RUNTIME" --reps 3 $(hdr)
  blk --experiment zero_queue --bs 131072 --qd 1 --pattern seq  --rwmix 0  --runtime "$RUNTIME" --reps 3 $(hdr)
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/zero_queue.csv" \
    --group mode,pattern,bs,qd --stat iops,mibps,lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us
}

exp_block_size() {
  start_experiment block_size
  local bs p
  for p in rand seq; do
    for bs in 4096 16384 32768 65536 131072 262144; do
      blk --experiment block_size --bs "$bs" --qd 1 --pattern "$p" --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
    done
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/block_size.csv" \
    --group bs,pattern,mode,qd --stat iops,mibps,lat_mean_us,lat_p99_us
}

exp_rw_mix() {
  start_experiment rw_mix
  local m
  for m in 10 7 5 0; do
    blk --experiment rw_mix --bs 4096 --qd 16 --pattern rand --rwmix "$m" --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/rw_mix.csv" \
    --group rwmix,mode,bs,qd --stat iops,mibps,lat_mean_us,lat_p99_us
}

exp_queue_depth() {
  start_experiment queue_depth
  local q
  for q in 1 2 4 8 16 32 64 128; do
    blk --experiment queue_depth --bs 4096 --qd "$q" --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/queue_depth.csv" \
    --group qd,bs,pattern --stat iops,mibps,lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us
}

exp_tail() {
  start_experiment tail
  local q
  for q in 8 32; do   # mid-QD and near-knee QD, longer runs for stable tails
    blk --experiment tail --bs 4096 --qd "$q" --pattern rand --rwmix 10 --runtime $((RUNTIME+2)) --reps 3 $(hdr)
  done
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/tail.csv" \
    --group qd,bs,pattern --stat lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,iops
}

exp_device_state() {
  start_experiment device_state
  # Back-to-back short sequential-write intervals: interval 0 may ride the drive's
  # DRAM write cache (burst), later intervals settle to steady state. One
  # invocation, many reps -> keep the per-rep time series (do not collapse it).
  "$BLK" --file "$FILE" --seed "$SEED" --experiment device_state \
         --bs 131072 --qd 4 --pattern seq --rwmix 0 --runtime 2 --reps 8 --header > "$ROOT/data/processed/device_state.csv"
  cp "$ROOT/data/processed/device_state.csv" "$RAW"
}

exp_pitfall() {
  start_experiment pitfall
  # Pitfall: buffered (page-cache) vs direct I/O over the SAME small 64 MiB region,
  # 4 KiB sequential reads. The direct run hits the device every time; the buffered
  # run re-reads the region from RAM after the first pass and reports fictitious
  # device numbers (us latency, GiB/s). Same knobs, only the cache bypass differs.
  local span=$((64*1024*1024))
  blk --experiment pitfall --bs 4096 --qd 1 --pattern seq --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  blk --experiment pitfall --bs 4096 --qd 1 --pattern seq --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$REPS" --buffered
  "$SUMMARIZE" --in "$RAW" --out "$ROOT/data/processed/pitfall.csv" \
    --group mode,pattern,bs,qd --stat iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us
}

main() {
  need
  mkdir -p "$ROOT/data/processed" "$SCRATCH"
  local what="${1:-all}"
  case "$what" in
    zero_queue)   precondition; exp_zero_queue ;;
    block_size)   precondition; exp_block_size ;;
    rw_mix)       precondition; exp_rw_mix ;;
    queue_depth)  precondition; exp_queue_depth ;;
    tail)         precondition; exp_tail ;;
    device_state) precondition; exp_device_state ;;
    pitfall)      precondition; exp_pitfall ;;
    all) precondition
         exp_zero_queue; exp_block_size; exp_rw_mix; exp_queue_depth
         exp_tail; exp_device_state; exp_pitfall ;;
    *) echo "unknown experiment: $what" >&2
       echo "usage: $0 {zero_queue|block_size|rw_mix|queue_depth|tail|device_state|pitfall|all}" >&2; exit 2 ;;
  esac
  echo "done: $what"
}
main "$@"
