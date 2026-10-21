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
#   4 zero_queue   QD=1 baselines again                                       [unstable seq-write row]
#   5 block_size   after REST_MIN; now with QD=32 random reads; WRITE_GAP_S pause before
#                  every write point                                          [clean >=256 KiB rand writes]
#   6 queue_depth  after REST_MIN; read + write curves, gaps before writes   [knee rule incl. QD=8 point]
#   7 fio_check    after REST_MIN; engine order alternates per repetition    [drive state vs engine]
#
#   rerun_clean.sh dryrun        plan, estimates, free-space / idle / TRIM checks; writes nothing
#   STEPS="tail block_size" rerun_clean.sh   run a subset (names as above, in the given order)
#
# Safety: identical to run.sh (sourced): disposable files in ACS_SCRATCH only, safety.sh gate,
# files deleted on exit. Refuses if free space < SUSTAIN_GIB + 10 GiB, if the drive is not
# idle (FORCE=1 overrides), or if no recent TRIM is detectable (TRIMMED=1 overrides).
set -euo pipefail
MODE="${1:-run}"

# ---- re-run defaults (all overridable from the environment) ------------------------
export SUSTAIN_GIB="${SUSTAIN_GIB:-60}" REPS="${REPS:-5}" WREPS="${WREPS:-3}"
export WRITE_GAP_S="${WRITE_GAP_S:-15}" WS_REVERSE="${WS_REVERSE:-1}" WS_REPS="${WS_REPS:-3}"
IDLE_AFTER_FILL_MIN="${IDLE_AFTER_FILL_MIN:-20}"
IDLE_BEFORE_TAIL_MIN="${IDLE_BEFORE_TAIL_MIN:-10}"
REST_MIN="${REST_MIN:-5}"
STEPS="${STEPS:-sustained working_set tail zero_queue block_size queue_depth fio_check}"
IDLE_MAX_WRITE_MIB="${IDLE_MAX_WRITE_MIB:-32}"   # idle check: max MiB written in 10 s
IDLE_MAX_BUSY_PCT="${IDLE_MAX_BUSY_PCT:-2}"      # idle check: max % of time the disk was busy

RUN_SH_LIB=1 source "$(dirname "$0")/run.sh"     # defines the experiments; cds to the project

# ---- estimates (GiB written / minutes), per step --------------------------------------
declare -A EST_GIB=( [sustained]=72 [working_set]=6 [tail]=2 [zero_queue]=7 [block_size]=24
                     [queue_depth]=14 [fio_check]=10 )
declare -A EST_MIN=( [sustained]=22 [working_set]=$((IDLE_AFTER_FILL_MIN+5)) [tail]=$((IDLE_BEFORE_TAIL_MIN+3))
                     [zero_queue]=2 [block_size]=$((REST_MIN+23)) [queue_depth]=$((REST_MIN+9))
                     [fio_check]=$((REST_MIN+6)) )
declare -A NOTE=(
  [sustained]="${SUSTAIN_GIB} GiB fill + <=8 GiB random + 60 s idle + <=4 GiB recovery (fill time depends on SLC size; capped at ${SUSTAIN_MAX_S}s)"
  [working_set]="idle ${IDLE_AFTER_FILL_MIN} min, then spans fwd+rev, ${WS_REPS} reps/pass; deletes the large file"
  [tail]="idle ${IDLE_BEFORE_TAIL_MIN} min, precondition 2 GiB, QD 8/32/64/128 reads"
  [zero_queue]="precondition + QD=1 baselines (write points capped)"
  [block_size]="rest ${REST_MIN} min; 56 points incl. QD=32 random reads; ${WRITE_GAP_S}s gap before each write point"
  [queue_depth]="rest ${REST_MIN} min; reads + writes QD 1-256; ${WRITE_GAP_S}s gap before each write point"
  [fio_check]="rest ${REST_MIN} min; 7 points x ${REPS} reps x 2 engines, order alternating" )

plan() {
  local s tg=0 tm=0
  printf '%-12s %8s %8s  %s\n' step "GiB-wr" "min" notes
  for s in $STEPS; do
    printf '%-12s %8s %8s  %s\n' "$s" "${EST_GIB[$s]:-?}" "${EST_MIN[$s]:-?}" "${NOTE[$s]:-}"
    tg=$((tg + ${EST_GIB[$s]:-0})); tm=$((tm + ${EST_MIN[$s]:-0}))
  done
  printf '%-12s %8s %8s  %s\n' TOTAL "~$tg" "~$tm" "upper bounds; peak space in use: ${SUSTAIN_GIB} GiB (large file) or 2 GiB (test file), never both"
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
  echo "== rerun_clean.sh $MODE  (scratch: $SCRATCH on $SRCDEV -> $DISK)"
  echo "REMINDER: run 'sudo fstrim -v /' first, then leave the machine idle >= 30 min."
  local avail need=$(( (SUSTAIN_GIB + 10) * GiB ))
  avail=$(avail_bytes)
  echo "free space: $(( avail / GiB )) GiB; required: $(( need / GiB )) GiB (large file + 10 GiB margin)"
  local ok=1
  [ "$avail" -ge "$need" ] || { echo "REFUSED: not enough free space (lower SUSTAIN_GIB)." >&2; ok=0; }
  [ "$(cat "/sys/block/$DISK/queue/rotational" 2>/dev/null)" = 0 ] || { echo "REFUSED: scratch is not on an SSD ($DISK)." >&2; ok=0; }
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

step() {
  local s="$1"
  echo; echo "=== step $s  ($(date -Is), temp $(temp_now) C)"
  case "$s" in
    sustained)   exp_sustained 1 ;;                                  # keep the file for working_set
    working_set) rest "$IDLE_AFTER_FILL_MIN" "let the fill's fold/GC backlog drain"
                 if [ -f "$BIG" ]; then BIG_FILLED=1 exp_working_set; else exp_working_set; fi ;;
    tail)        rm -f -- "$BIG"; rest "$IDLE_BEFORE_TAIL_MIN" "drain before tail"; precondition; exp_tail ;;
    zero_queue)  precondition; exp_zero_queue ;;
    block_size)  rest "$REST_MIN" "drain"; precondition; exp_block_size ;;
    queue_depth) rest "$REST_MIN" "drain"; precondition; exp_queue_depth ;;
    fio_check)   rest "$REST_MIN" "drain"; if have_fio; then precondition; fi; exp_fio_check ;;
    *) echo "unknown step $s" >&2; exit 2 ;;
  esac
}

case "$MODE" in
  dryrun) need; preflight || echo "(dryrun: the real run would refuse; see above)"; exit 0 ;;
  run)    ;;
  *) echo "usage: $0 [dryrun]" >&2; exit 2 ;;
esac

need
mkdir -p "$P" "$SCRATCH" "$ROOT/data/raw"
LOG="$ROOT/data/raw/rerun_clean_$TS.log"
exec > >(tee -a "$LOG") 2>&1
preflight || { echo "rerun_clean: refusing to start" >&2; exit 1; }
trap cleanup EXIT
echo "# TRIM evidence and knobs recorded in $LOG; raw runs: data/raw/<exp>/$TS/"
for s in $STEPS; do step "$s"; done
echo; echo "done $(date -Is). Next: scripts/sync_data.sh SSD_Performance_Profiling (from ACS-Code), then rebuild the paper."
