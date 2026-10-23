#!/usr/bin/env bash
# rerun_clean.sh — clean re-run of the SSD experiments whose 2026-10-21 results were
# confounded by drive state (run order, no TRIM, no idle). Run it AFTER:
#
#   sudo fstrim -v /                      # hand the deleted blocks back to the SSD
#   # ...then leave the machine idle for >= 30 minutes (no heavy disk I/O)
#   ACS_SCRATCH=$HOME/acs_ssd_scratch SSD_Performance_Profiling/scripts/rerun_clean.sh dryrun
#   ACS_SCRATCH=$HOME/acs_ssd_scratch SSD_Performance_Profiling/scripts/rerun_clean.sh
#
# Order (each step's purpose in brackets):
#   1 sustained    60 GiB sequential fill FIRST, on the trimmed + idle drive  [fresh SLC size + cliff]
#                  then 4 KiB random-write phase, 60 s idle, recovery burst
#   2 working_set  after IDLE_AFTER_FILL_MIN idle; spans 1,4,16,60 GiB forward then reverse
#                  (WS_REVERSE=1, WS_REPS=3 per pass)                         [span not confounded with time]
#   3 tail         after IDLE_BEFORE_TAIL_MIN idle, on a freshly preconditioned 2 GiB file
#                                                                             [tails without GC backlog]
#   4 zero_queue   after REST_MIN; QD=1 baselines, SLOW_GAP_S pause before each write point
#                                                                             [unstable seq-write row]
#   4b rw_mix      after REST_MIN; read/write mixes, SLOW_GAP_S pause before each mix with writes
#                                                                             [mixes on an idle drive]
#   5 block_size   after REST_MIN; now with QD=32 random reads; WRITE_GAP_S pause before
#                  every write point                                          [clean >=256 KiB rand writes]
#   6 queue_depth  after REST_MIN; read + write curves, gaps before writes   [knee rule incl. QD=8 point]
#   7 fio_check    after REST_MIN; engine order alternates per repetition    [drive state vs engine]
#
#   rerun_clean.sh dryrun        plan, estimates, free-space / idle / TRIM checks; writes nothing
#
# LEAN mode (~35 GiB expected, <= ~55 GiB max, ~35-50 min):  rerun_clean.sh lean [dryrun]
#   1 sustained    fill up to 40 GiB, STOPPING 10 s after throughput stays below 30% of the
#                  first-5-s burst median (stop-at-cliff; no cliff by 40 GiB => "cache >= 40 GiB");
#                  random-write phase <=60 s / 2 GiB over the written part; 60 s idle; <=10 s /
#                  1 GiB recovery probe; large file deleted right after
#   2 tail         rest LEAN_REST_MIN (10), precondition a 4 GiB test file, QD 8/32/64/128 on its
#                  first 2 GiB (same LBA range as the original sweeps)
#   3 working_set  spans 1,2,4 GiB of the test file, forward then reverse, 2 reps/pass, 64 MiB cap
#   4 block_size   QD=32 random reads 4 KiB-1 MiB (read-only), rest LEAN_REST2_MIN (5), then the
#                  QD=1 random writes at 256 KiB/512 KiB/1 MiB again (128 MiB cap, 15 s gaps)
#   5 queue_depth  random-write points QD 4/8/16/32 (128 MiB cap, 15 s gaps)
#   6 fio_check    write points only (4 KiB rand QD1/QD32, 128 KiB seq QD1), engine order alternating
#   plus an NVMe SMART snapshot before and after (nvme-cli `nvme smart-log`, if it works without
#   root; otherwise hwmon temperature only). Partial re-measurements go to <exp>_lean raw dirs and
#   replace only the matching configurations of the earlier full run (run.sh merge_lean).
#   STEPS="tail block_size" rerun_clean.sh   run a subset (names as above, in the given order)
#
# Safety: identical to run.sh (sourced): disposable files in ACS_SCRATCH only, safety.sh gate,
# files deleted on exit. Refuses if free space < SUSTAIN_GIB + 10 GiB, if the drive is not
# idle (FORCE=1 overrides), or if no recent TRIM is detectable (TRIMMED=1 overrides).
set -euo pipefail
LEAN=0; MODE=run
for a in "$@"; do case "$a" in lean) LEAN=1;; dryrun) MODE=dryrun;; run) ;; *) echo "usage: $0 [lean] [dryrun]" >&2; exit 2;; esac; done

if [ "$LEAN" = 1 ]; then
  export SUSTAIN_GIB="${SUSTAIN_GIB:-40}" STOP_BELOW="${STOP_BELOW:-0.3}" STOP_HOLD="${STOP_HOLD:-10}"
  export SUSTAIN_MAX_S="${SUSTAIN_MAX_S:-900}" RAND_S="${RAND_S:-60}" RAND_CAP_GIB="${RAND_CAP_GIB:-1}"
  export IDLE_S="${IDLE_S:-60}" RECOVER_S="${RECOVER_S:-10}" RECOVER_CAP_GIB="${RECOVER_CAP_GIB:-1}"
  export FSIZE_MIB="${FSIZE_MIB:-4096}" WRITE_CAP_MIB="${WRITE_CAP_MIB:-128}" FIO_REPS="${FIO_REPS:-4}"
  export DEFAULT_SPAN_BYTES="${DEFAULT_SPAN_BYTES:-$((2*1024*1024*1024))}"
  LEAN_REST_MIN="${LEAN_REST_MIN:-10}"; LEAN_REST2_MIN="${LEAN_REST2_MIN:-5}"
  LEAN_WS_GIB="${LEAN_WS_GIB:-1 2 4}"; LEAN_WS_REPS="${LEAN_WS_REPS:-2}"; LEAN_WS_CAP_MIB="${LEAN_WS_CAP_MIB:-64}"
  STEPS="${STEPS:-sustained tail working_set block_size queue_depth fio_check}"
fi

# ---- re-run defaults (all overridable from the environment) ------------------------
export SUSTAIN_GIB="${SUSTAIN_GIB:-60}" REPS="${REPS:-5}" WREPS="${WREPS:-3}"
export WRITE_GAP_S="${WRITE_GAP_S:-15}" WS_REVERSE="${WS_REVERSE:-1}" WS_REPS="${WS_REPS:-3}"
IDLE_AFTER_FILL_MIN="${IDLE_AFTER_FILL_MIN:-20}"
IDLE_BEFORE_TAIL_MIN="${IDLE_BEFORE_TAIL_MIN:-10}"
REST_MIN="${REST_MIN:-5}"
SLOW_GAP_S="${SLOW_GAP_S:-120}"   # longer write gap for zero_queue/rw_mix, whose 2 GiB re-fills precede writes
STEPS="${STEPS:-sustained working_set tail zero_queue rw_mix block_size queue_depth fio_check}"
IDLE_MAX_WRITE_MIB="${IDLE_MAX_WRITE_MIB:-32}"   # idle check: max MiB written in 10 s
IDLE_MAX_BUSY_PCT="${IDLE_MAX_BUSY_PCT:-2}"      # idle check: max % of time the disk was busy

RUN_SH_LIB=1 source "$(dirname "$0")/run.sh"     # defines the experiments; cds to the project

# ---- estimates (GiB written / minutes), per step --------------------------------------
declare -A EST_GIB=( [sustained]=72 [working_set]=6 [tail]=2 [zero_queue]=7 [rw_mix]=4 [block_size]=24
                     [queue_depth]=14 [fio_check]=10 )
declare -A EST_MIN=( [sustained]=22 [working_set]=$((IDLE_AFTER_FILL_MIN+5)) [tail]=$((IDLE_BEFORE_TAIL_MIN+3))
                     [zero_queue]=$((REST_MIN+9)) [rw_mix]=$((REST_MIN+9)) [block_size]=$((REST_MIN+23)) [queue_depth]=$((REST_MIN+9))
                     [fio_check]=$((REST_MIN+6)) )
declare -A EST_MAX=()
if [ "$LEAN" = 1 ]; then   # expected / max GiB written and minutes
  EST_GIB=( [sustained]=23 [tail]=4 [working_set]=1 [block_size]=1 [queue_depth]=3 [fio_check]=3 )
  EST_MAX=( [sustained]=$((SUSTAIN_GIB+RAND_CAP_GIB+RECOVER_CAP_GIB)) [tail]=$((FSIZE_MIB/1024)) [working_set]=1 [block_size]=2 [queue_depth]=3 [fio_check]=3 )
  EST_MIN=( [sustained]=4 [tail]=$((LEAN_REST_MIN+3)) [working_set]=3 [block_size]=$((LEAN_REST2_MIN+5))
            [queue_depth]=3 [fio_check]=3 )
fi
declare -A NOTE=(
  [sustained]="${SUSTAIN_GIB} GiB fill + <=8 GiB random + 60 s idle + <=4 GiB recovery (fill time depends on SLC size; capped at ${SUSTAIN_MAX_S}s)"
  [working_set]="idle ${IDLE_AFTER_FILL_MIN} min, then spans fwd+rev, ${WS_REPS} reps/pass; deletes the large file"
  [tail]="idle ${IDLE_BEFORE_TAIL_MIN} min, precondition 2 GiB, QD 8/32/64/128 reads"
  [zero_queue]="rest ${REST_MIN} min; precondition + QD=1 baselines; ${SLOW_GAP_S}s gap before each write point"
  [rw_mix]="rest ${REST_MIN} min; precondition + 4 mixes at QD=16; ${SLOW_GAP_S}s gap before each mix with writes"
  [block_size]="rest ${REST_MIN} min; 56 points incl. QD=32 random reads; ${WRITE_GAP_S}s gap before each write point"
  [queue_depth]="rest ${REST_MIN} min; reads + writes QD 1-256; ${WRITE_GAP_S}s gap before each write point"
  [fio_check]="rest ${REST_MIN} min; 7 points x ${REPS} reps x 2 engines, order alternating" )
if [ "$LEAN" = 1 ]; then NOTE=(
  [sustained]="fill <=${SUSTAIN_GIB} GiB, stop ${STOP_HOLD}s after <${STOP_BELOW} x burst (expected ~20 GiB if the fresh cache is ~20 GiB); rand <=${RAND_S}s/${RAND_CAP_GIB} GiB; idle ${IDLE_S}s; recovery <=${RECOVER_S}s/${RECOVER_CAP_GIB} GiB; max time ${SUSTAIN_MAX_S}s fill"
  [tail]="rest ${LEAN_REST_MIN} min; precondition ${FSIZE_MIB} MiB test file; QD 8/32/64/128 on first 2 GiB"
  [working_set]="spans ${LEAN_WS_GIB} GiB fwd+rev, ${LEAN_WS_REPS} reps/pass, ${LEAN_WS_CAP_MIB} MiB write cap"
  [block_size]="QD32 rand reads 8 sizes (read-only); rest ${LEAN_REST2_MIN} min; rand writes 256K/512K/1M x ${WREPS}, ${WRITE_CAP_MIB} MiB cap"
  [queue_depth]="rand writes QD 4/8/16/32 x ${REPS}, ${WRITE_CAP_MIB} MiB cap, ${WRITE_GAP_S}s gaps"
  [fio_check]="3 write points x ${FIO_REPS} reps x 2 engines, alternating order, ${WRITE_CAP_MIB} MiB cap" ); fi

plan() {
  local s tg=0 tm=0 tx=0
  printf '%-12s %8s %8s %8s  %s\n' step "GiB-exp" "GiB-max" "min" notes
  for s in $STEPS; do
    printf '%-12s %8s %8s %8s  %s\n' "$s" "${EST_GIB[$s]:-?}" "${EST_MAX[$s]:-${EST_GIB[$s]:-?}}" "${EST_MIN[$s]:-?}" "${NOTE[$s]:-}"
    tg=$((tg + ${EST_GIB[$s]:-0})); tx=$((tx + ${EST_MAX[$s]:-${EST_GIB[$s]:-0}})); tm=$((tm + ${EST_MIN[$s]:-0}))
  done
  printf '%-12s %8s %8s %8s  %s\n' TOTAL "~$tg" "~$tx" "~$tm" "peak space in use: ${SUSTAIN_GIB} GiB (large file) or $((FSIZE_MIB/1024)) GiB (test file), never both"
  [ "$LEAN" = 1 ] && echo "  (lean: if the fill finds no cliff it writes the full ${SUSTAIN_GIB} GiB, at most ${SUSTAIN_MAX_S}s; time then grows by up to ~12 min)"
  return 0
}

# ---- drive checks ------------------------------------------------------------------------
disk_stat() { awk '{print $3, $7, $10}' "/sys/block/$DISK/stat"; }   # sectors read, sectors written, io_ticks(ms)
idle_check() {
  local r0 w0 t0 r1 w1 t1 wmib busy
  read -r r0 w0 t0 < <(disk_stat); sleep 10; read -r r1 w1 t1 < <(disk_stat)
  wmib=$(( (w1 - w0) * 512 / 1048576 )); busy=$(( (t1 - t0) / 100 ))   # % of 10 000 ms
  echo "idle check on $DISK over 10 s: read $(( (r1 - r0) * 512 / 1048576 )) MiB, wrote $wmib MiB, busy ${busy}%"
  if [ "$wmib" -gt "$IDLE_MAX_WRITE_MIB" ] || [ "$busy" -gt "$IDLE_MAX_BUSY_PCT" ]; then
    echo "drive is NOT idle (limits: ${IDLE_MAX_WRITE_MIB} MiB written, ${IDLE_MAX_BUSY_PCT}% busy)." >&2
    return 1
  fi
}
trim_evidence() {
  # Best effort: manual `sudo fstrim` and the fstrim.service both leave journal entries.
  { journalctl -q --no-pager --since "-12h" _COMM=fstrim 2>/dev/null
    journalctl -q --no-pager --since "-12h" _COMM=sudo 2>/dev/null | grep -i fstrim
    journalctl -q --no-pager --since "-12h" -u fstrim.service 2>/dev/null; } | tail -5
}
rest() {   # idle for N minutes, logging temperature and disk activity once a minute
  local n="$1" why="$2" i
  echo "[rest] ${n} min ($why)"
  for ((i=1; i<=n; i++)); do
    sleep 60
    echo "  rest ${i}/${n} min  temp $(temp_now) C  stat $(disk_stat)"
  done
}

preflight() {
  echo "== rerun_clean.sh $MODE$([ "$LEAN" = 1 ] && echo ' (lean)')  (scratch: $SCRATCH on $SRCDEV -> $DISK)"
  echo "REMINDER: run 'sudo fstrim -v /' first, then leave the machine idle >= 30 min."
  local avail need=$(( (SUSTAIN_GIB + 10) * GiB ))
  avail=$(avail_bytes)
  echo "free space: $(( avail / GiB )) GiB; required: $(( need / GiB )) GiB (large file + 10 GiB margin)"
  local ok=1
  [ "$avail" -ge "$need" ] || { echo "REFUSED: not enough free space (lower SUSTAIN_GIB)." >&2; ok=0; }
  # ALLOW_NONSSD=1 is for testing the script on a RAM disk (tmpfs) only
  [ "$(cat "/sys/block/$DISK/queue/rotational" 2>/dev/null)" = 0 ] || [ "${ALLOW_NONSSD:-0}" = 1 ] \
    || { echo "REFUSED: scratch is not on an SSD ($DISK)." >&2; ok=0; }
  local ev; ev="$(trim_evidence)"
  echo "TRIM evidence (journal, last 12 h):"; echo "${ev:-  (none found)}" | sed 's/^/  /'
  echo "fstrim.service last run: $(systemctl show fstrim.service -p ExecMainExitTimestamp --value 2>/dev/null)"
  if ! echo "$ev" | grep -qiE 'fstrim|trimmed' && [ "${TRIMMED:-0}" != 1 ]; then
    echo "REFUSED: no recent fstrim found in the journal. Run 'sudo fstrim -v /' (or set TRIMMED=1 if you did)." >&2; ok=0
  fi
  if ! idle_check; then [ "${FORCE:-0}" = 1 ] && echo "FORCE=1: continuing anyway" || ok=0; fi
  echo; plan; echo
  [ "$ok" = 1 ]
}

smart_snap() {   # read-only health snapshot; nvme-cli usually needs root, then only hwmon is recorded
  local out="$ROOT/data/raw/smart/${TS}_$1.txt"; mkdir -p "$(dirname "$out")"
  { echo "# $(date -Is) $1"
    echo "# hwmon composite temperature: $(temp_now) C"
    if command -v nvme >/dev/null 2>&1; then
      timeout 20 nvme smart-log "/dev/$(basename "$(readlink -f "/sys/block/$DISK/device")")" -o json 2>&1 \
        || echo "# nvme smart-log failed (no root?); hwmon only"
    else echo "# nvme-cli not installed; hwmon only"; fi; } > "$out"
  echo "[smart] $1 -> $out"
}
lean_ws() {
  start_experiment working_set
  local order g span tmp="$RAWDIR/ws.tmp" cap=$((LEAN_WS_CAP_MIB*MiB))
  order="$LEAN_WS_GIB $(echo $LEAN_WS_GIB | tr ' ' '\n' | tac | tr '\n' ' ')"
  echo "# lean working set on the $FSIZE_MIB MiB test file; span order: $order; reps/pass $LEAN_WS_REPS; cap $LEAN_WS_CAP_MIB MiB" >> "$RAWDIR/env.txt"
  for g in $order; do
    span=$((g*GiB)); : > "$tmp"
    RAW="$tmp" blk --experiment working_set --bs 4096 --qd 1  --pattern rand --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$LEAN_WS_REPS" --header
    RAW="$tmp" blk --experiment working_set --bs 4096 --qd 32 --pattern rand --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$LEAN_WS_REPS"
    RAW="$tmp" blk --experiment working_set --bs 4096 --qd 32 --pattern rand --rwmix 0  --span "$span" --runtime "$RUNTIME" --reps "$LEAN_WS_REPS" --max-bytes "$cap"
    awk -F, -v g="$g" -v first="$([ -s "$RAW" ] && echo 0 || echo 1)" 'NR==1{ if(first) print "span_gib,"$0; next} {print g","$0}' "$tmp" >> "$RAW"
  done
  rm -f "$tmp"; end_experiment; sum_working_set "$RAW"
}
lean_bs() {
  start_experiment block_size_lean
  local bs
  for bs in 4096 16384 32768 65536 131072 262144 524288 1048576; do
    blk --experiment block_size --bs "$bs" --qd 32 --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  done
  rest "$LEAN_REST2_MIN" "drain before the large random writes"
  for bs in 262144 524288 1048576; do
    wgap
    blk --experiment block_size --bs "$bs" --qd 1 --pattern rand --rwmix 0 --runtime "$RUNTIME" --reps "$WREPS" --max-bytes "$WCAP" $(hdr)
  done
  end_experiment; sum_with_lean block_size
}
lean_qd() {
  start_experiment queue_depth_lean
  local q
  for q in 4 8 16 32; do
    wgap
    blk --experiment queue_depth --bs 4096 --qd "$q" --pattern rand --rwmix 0 --runtime "$RUNTIME" --reps "$REPS" --max-bytes "$WCAP" $(hdr)
  done
  end_experiment; sum_with_lean queue_depth
}
lean_info() {
  { echo "run_date,ts,remeasured"
    echo "$(date +%F),$TS,sustained; tail; working_set (1-4 GiB); block_size (QD32 rand read + QD1 rand write >=256K); queue_depth (write QD4-32); fio_check (writes)"
  } > "$P/lean_info.csv"
}

step() {
  local s="$1"
  if [ "$LEAN" = 1 ]; then
    echo; echo "=== lean step $s  ($(date -Is), temp $(temp_now) C)"
    case "$s" in
      sustained)   exp_sustained 0 ;;                                # big file deleted right after
      tail)        rm -f -- "$BIG"; rest "$LEAN_REST_MIN" "drain after the fill"; precondition; exp_tail ;;
      working_set) lean_ws ;;
      block_size)  lean_bs ;;
      queue_depth) lean_qd ;;
      fio_check)   if have_fio; then FIO_EXP_NAME=fio_check_lean FIO_POINTS="4096 1 rand 0;4096 32 rand 0;131072 1 seq 0" exp_fio_check
                   else echo "[fio_check] skipped: fio not installed"; fi ;;
      *) echo "unknown lean step $s" >&2; exit 2 ;;
    esac
    return
  fi
  echo; echo "=== step $s  ($(date -Is), temp $(temp_now) C)"
  case "$s" in
    sustained)   exp_sustained 1 ;;                                  # keep the file for working_set
    working_set) rest "$IDLE_AFTER_FILL_MIN" "let the fill's fold/GC backlog drain"
                 if [ -f "$BIG" ]; then BIG_FILLED=1 exp_working_set; else exp_working_set; fi ;;
    tail)        rm -f -- "$BIG"; rest "$IDLE_BEFORE_TAIL_MIN" "drain before tail"; precondition; exp_tail ;;
    zero_queue)  rest "$REST_MIN" "drain"; precondition
                 g="$WRITE_GAP_S"; WRITE_GAP_S="$SLOW_GAP_S"; exp_zero_queue; WRITE_GAP_S="$g" ;;
    rw_mix)      rest "$REST_MIN" "drain"; precondition
                 g="$WRITE_GAP_S"; WRITE_GAP_S="$SLOW_GAP_S"; exp_rw_mix; WRITE_GAP_S="$g" ;;
    block_size)  rest "$REST_MIN" "drain"; precondition; exp_block_size ;;
    queue_depth) rest "$REST_MIN" "drain"; precondition; exp_queue_depth ;;
    fio_check)   rest "$REST_MIN" "drain"; if have_fio; then precondition; fi; exp_fio_check ;;
    *) echo "unknown step $s" >&2; exit 2 ;;
  esac
}

if [ "$MODE" = dryrun ]; then
  need; preflight || echo "(dryrun: the real run would refuse; see above)"
  if command -v nvme >/dev/null 2>&1; then echo "nvme-cli present: SMART snapshot will be attempted (read-only; may need root)"
  else echo "nvme-cli not installed: SMART snapshot = hwmon temperature only"; fi
  exit 0
fi

need
mkdir -p "$P" "$SCRATCH" "$ROOT/data/raw"
LOG="$ROOT/data/raw/rerun_clean_$TS.log"
exec > >(tee -a "$LOG") 2>&1
preflight || { echo "rerun_clean: refusing to start" >&2; exit 1; }
trap cleanup EXIT
echo "# TRIM evidence and knobs recorded in $LOG; raw runs: data/raw/<exp>/$TS/"
[ "$LEAN" = 1 ] && smart_snap before
for s in $STEPS; do step "$s"; done
[ "$LEAN" = 1 ] && { smart_snap after; lean_info; }
echo; echo "done $(date -Is). Next: common/code/scripts/sync_data.sh SSD_Performance_Profiling (from the repository root), then rebuild the paper."
