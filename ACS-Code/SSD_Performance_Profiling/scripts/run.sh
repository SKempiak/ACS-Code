#!/usr/bin/env bash
# run.sh — experiment driver for Project 3 (SSD / storage performance profiling).
#
#   scripts/run.sh <experiment>     one of:
#       zero_queue block_size rw_mix queue_depth tail pitfall layout   (2 GiB test file)
#       working_set sustained device_state                          (large file, see below)
#       fio_check                                                   (needs fio; skips cleanly)
#   scripts/run.sh all              the 2 GiB-file experiments + fio_check (NOT the large
#                                   device-state runs, which must be started explicitly)
#   scripts/run.sh reprocess        re-summarize the newest raw run of every experiment
#   scripts/run.sh dryrun           print the plan, sizes and safety checks; write nothing
#
# All I/O is direct (O_DIRECT) against DISPOSABLE files in the scratch directory,
# gated by scripts/safety.sh (which refuses any device, partition, mountpoint or
# path outside the scratch directory). build/blkbench (libaio) is the primary
# engine; ENGINE=fio routes the standard sweeps through fio/job.fio instead, and
# `fio_check` runs both engines on the same points. Both emit the same CSV
# schema, reduced by tools/summarize into data/processed/<experiment>.csv for the
# ACS-Latex figures. Scratch files are deleted on exit (KEEP_SCRATCH=1 keeps them).
#
# DEVICE UNDER TEST: whatever filesystem holds the scratch directory. The default
# in-repo data/scratch/ may sit on a different disk than the SSD (on the test host
# it is the SATA HDD); set ACS_SCRATCH to a directory on the SSD, e.g.
#   ACS_SCRATCH=$HOME/acs_ssd_scratch scripts/run.sh zero_queue
# env.txt records the resolved parent disk, its rotational flag, model, firmware,
# PCIe link and temperature so a run can never be silently mislabelled.
#
# Knobs (environment):
#   FSIZE_MIB=2048     test-file size for the standard sweeps (LBA range used)
#   RUNTIME=4          seconds per repetition          REPS=5   repetitions per point
#   WREPS=3            repetitions for write points in block_size (byte budget)
#   WRITE_CAP_MIB=256  per-repetition byte cap for points that write (byte budget)
#   SEED=20260312      offsets + data-pattern seed     ENGINE=blkbench|fio
#   SUSTAIN_GIB=64     size of the large file = volume of the sustained sequential
#                      fill (refused unless free space >= size + 10 GiB)
#   SUSTAIN_MAX_S=3600 time cap on the sustained fill
#   RAND_S=180 RAND_CAP_GIB=8   steady-state 4 KiB random-write phase (time / bytes)
#   IDLE_S=60          idle (temperature-only) gap before the recovery burst
#   RECOVER_S=15 RECOVER_CAP_GIB=4   recovery burst after the idle gap
#   WS_LIST_GIB="1 4 16 $SUSTAIN_GIB"  working-set spans (each <= SUSTAIN_GIB)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CODE_ROOT="$(cd .. && pwd)"
SUMMARIZE="$CODE_ROOT/build/tools/summarize"
BLK="$ROOT/build/blkbench"
SAFE="$ROOT/scripts/safety.sh"
SCRATCH="${ACS_SCRATCH:-$ROOT/data/scratch}"
FILE="$SCRATCH/testfile.bin"
BIG="$SCRATCH/bigfile.bin"

GiB=$((1024*1024*1024)); MiB=$((1024*1024))
FSIZE_MIB="${FSIZE_MIB:-2048}"
RUNTIME="${RUNTIME:-4}"
REPS="${REPS:-5}"
WREPS="${WREPS:-3}"
WRITE_CAP_MIB="${WRITE_CAP_MIB:-256}"
SEED="${SEED:-20260312}"
ENGINE="${ENGINE:-blkbench}"
SUSTAIN_GIB="${SUSTAIN_GIB:-64}"
SUSTAIN_MAX_S="${SUSTAIN_MAX_S:-3600}"
RAND_S="${RAND_S:-180}"
RAND_CAP_GIB="${RAND_CAP_GIB:-8}"
IDLE_S="${IDLE_S:-60}"
RECOVER_S="${RECOVER_S:-15}"
RECOVER_CAP_GIB="${RECOVER_CAP_GIB:-4}"
WS_LIST_GIB="${WS_LIST_GIB:-1 4 16 $SUSTAIN_GIB}"
MARGIN=$((10*GiB))                 # free space that must remain after the large file
KEEP_SCRATCH="${KEEP_SCRATCH:-0}"
TS="$(date +%Y%m%d-%H%M%S)"
WCAP=$((WRITE_CAP_MIB*MiB))

# ------------------------------------------------------------------ helpers
need() { [ -x "$BLK" ] || { echo "missing $BLK; run 'make'" >&2; exit 1; }
         [ -x "$SUMMARIZE" ] || { echo "missing $SUMMARIZE; run 'make tools' in ACS-Code" >&2; exit 1; }; }
have_fio() { command -v fio >/dev/null 2>&1; }

cleanup() {
  [ "$KEEP_SCRATCH" = 1 ] && return 0
  rm -f -- "$FILE" "$BIG"
}

# NVMe composite temperature, readable without root: the controller's hwmon node.
find_temp() {
  local disk="$1" f
  for f in /sys/block/"$disk"/device/hwmon*/temp1_input; do [ -r "$f" ] && { echo "$f"; return; }; done
  for f in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$f/name" 2>/dev/null)" = nvme ] && [ -r "$f/temp1_input" ] && { echo "$f/temp1_input"; return; }
  done
  echo ""
}
temp_now() { [ -n "$TEMP" ] && awk '{printf "%.2f", $1/1000}' "$TEMP" 2>/dev/null || echo -1; }

# Partition -> parent disk (nvme0n1p3 -> nvme0n1, sda1 -> sda); whole disks map to themselves.
parent_disk() {
  local name; name="$(basename "$1")"
  local pk; pk="$(lsblk -no PKNAME "/dev/$name" 2>/dev/null | head -1 | tr -d ' ')"
  if [ -n "$pk" ]; then echo "$pk"; return; fi
  if [ -e "/sys/class/block/$name/partition" ]; then
    basename "$(readlink -f "/sys/class/block/$name/..")"; return
  fi
  echo "$name"
}

mkdir -p "$SCRATCH"
SRCDEV="$(df --output=source "$SCRATCH" 2>/dev/null | tail -1)"
DISK="$(parent_disk "$SRCDEV")"
TEMP="$(find_temp "$DISK")"
TEMP_ARGS=(); [ -n "$TEMP" ] && TEMP_ARGS=(--temp "$TEMP")

avail_bytes() { df -B1 --output=avail "$SCRATCH" | tail -1 | tr -d ' '; }

device_report() {
  local sys="/sys/block/$DISK"
  echo "# --- storage device under test ---"
  df -hT "$SCRATCH" 2>/dev/null
  echo "# scratch dir: $SCRATCH"
  echo "# source device: $SRCDEV  -> parent disk: $DISK"
  echo "# mount options: $(findmnt -no OPTIONS --target "$SCRATCH" 2>/dev/null)"
  lsblk -o NAME,ROTA,SIZE,MODEL,MOUNTPOINT 2>/dev/null
  echo "# rotational: $(cat "$sys/queue/rotational" 2>/dev/null || echo '?') (1=HDD,0=SSD)"
  echo "# scheduler: $(cat "$sys/queue/scheduler" 2>/dev/null)  nr_requests: $(cat "$sys/queue/nr_requests" 2>/dev/null)  write_cache: $(cat "$sys/queue/write_cache" 2>/dev/null)"
  if [ -d "$sys/device" ] && [ -r "$sys/device/model" ]; then
    echo "# model: $(tr -s ' ' < "$sys/device/model")  firmware: $(tr -d ' ' < "$sys/device/firmware_rev" 2>/dev/null)"
    echo "# nvme queues: $(cat "$sys/device/queue_count" 2>/dev/null)  sqsize: $(cat "$sys/device/sqsize" 2>/dev/null)"
    local pci="$sys/device/device"
    echo "# pcie link: current $(cat "$pci/current_link_speed" 2>/dev/null) x$(cat "$pci/current_link_width" 2>/dev/null); max $(cat "$pci/max_link_speed" 2>/dev/null) x$(cat "$pci/max_link_width" 2>/dev/null)"
  fi
  echo "# temperature sensor: ${TEMP:-none}  now: $(temp_now) C"
  if [ -n "$TEMP" ]; then
    local h; h="$(dirname "$TEMP")"
    echo "# thresholds: warning (temp1_max) $(awk '{print $1/1000}' "$h/temp1_max" 2>/dev/null) C, critical (temp1_crit) $(awk '{print $1/1000}' "$h/temp1_crit" 2>/dev/null) C"
  fi
  echo "# fstrim.timer: $(systemctl is-enabled fstrim.timer 2>/dev/null || echo unknown)"
}

start_experiment() {
  local exp="$1"
  RAWDIR="$ROOT/data/raw/$exp/$TS"; mkdir -p "$RAWDIR"
  RAW="$RAWDIR/raw.csv"; : > "$RAW"
  echo "[$exp] -> $RAW  (engine=$ENGINE, reps=$REPS, runtime=${RUNTIME}s, temp $(temp_now) C)"
  { "$CODE_ROOT/scripts/collect_env.sh" 2>/dev/null || true
    device_report
    echo "# test file: $FILE (${FSIZE_MIB} MiB); large file: $BIG (${SUSTAIN_GIB} GiB, device-state runs only)"
    echo "# knobs: RUNTIME=$RUNTIME REPS=$REPS WREPS=$WREPS WRITE_CAP_MIB=$WRITE_CAP_MIB SEED=$SEED ENGINE=$ENGINE"
    echo "# data pattern: incompressible xorshift64* fill, generated once per buffer (blkbench --fill rand)"
    echo "# start: $(date -Is)"
  } > "$RAWDIR/env.txt" 2>&1
}
end_experiment() {
  echo "# end: $(date -Is)  temperature: $(temp_now) C" >> "$RAWDIR/env.txt"
}
hdr() { [ -s "$RAW" ] || echo "--header"; }
# wgap: optional pause before a write point so one point's flush backlog does not spill
# into the next (WRITE_GAP_S, default 0; rerun_clean.sh sets it). Logged in timeline.csv.
WRITE_GAP_S="${WRITE_GAP_S:-0}"
wgap() { [ "$WRITE_GAP_S" -gt 0 ] 2>/dev/null && { echo "$(date +%s),gap,$WRITE_GAP_S" >> "$RAWDIR/timeline.csv"; sleep "$WRITE_GAP_S"; }; return 0; }

# blk <blkbench args...> : one measurement point, appended to $RAW.
# With ENGINE=fio the same point is run through fio/job.fio (one fio call per rep).
# DEFAULT_SPAN_BYTES>0 restricts every point to the first N bytes of the target unless the
# point passes its own --span (later options win); rerun_clean.sh lean uses it to keep the
# 2 GiB LBA range of the original sweeps on a larger test file.
DEFAULT_SPAN_BYTES="${DEFAULT_SPAN_BYTES:-0}"
blk() {
  local pre=(); [ "$DEFAULT_SPAN_BYTES" -gt 0 ] && pre=(--span "$DEFAULT_SPAN_BYTES")
  echo "$(date +%s),${ENGINE},${pre[*]} $*" >> "$RAWDIR/timeline.csv"   # wall-clock order of every point
  if [ "$ENGINE" = fio ]; then fio_point "${pre[@]}" "$@"; return; fi
  "$BLK" --file "${TARGET:-$FILE}" --seed "$SEED" "${TEMP_ARGS[@]}" "${pre[@]}" "$@" >> "$RAW"
}

# ------------------------------------------------------------------ fio path
# Translate blkbench-style arguments into fio/job.fio environment variables.
fio_point() {
  have_fio || { echo "ENGINE=fio but fio is not installed" >&2; exit 1; }
  local exp=ssd bs=4096 qd=1 pat=rand rwmix=10 rt="$RUNTIME" reps=1 span=0 cap=0 direct=1 label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --experiment) exp="$2"; shift 2;;  --bs) bs="$2"; shift 2;;  --qd) qd="$2"; shift 2;;
      --pattern) pat="$2"; shift 2;;     --rwmix) rwmix="$2"; shift 2;;
      --runtime) rt="$2"; shift 2;;      --reps) reps="$2"; shift 2;;
      --span) span="$2"; shift 2;;       --max-bytes) cap="$2"; shift 2;;
      --buffered) direct=0; label="-buffered"; shift;;
      --header) shift;;
      *) echo "fio_point: unsupported option $1" >&2; exit 1;;
    esac
  done
  local tgt="${TARGET:-$FILE}" size
  size=$(stat -c %s "$tgt"); [ "$span" -gt 0 ] && [ "$span" -lt "$size" ] && size="$span"
  local mode rw
  if   [ "$rwmix" -ge 10 ]; then mode=read;  rw=read
  elif [ "$rwmix" -le 0 ];  then mode=write; rw=write
  else                           mode=rw;    rw=rw; fi
  [ "$pat" = rand ] && rw="rand$rw"
  local iosize="$cap"; [ "$iosize" -gt 0 ] || iosize=$((1024*GiB))   # runtime-bound unless capped
  mkdir -p "$RAWDIR/fio"
  local r json
  for ((r=0; r<reps; r++)); do
    json="$RAWDIR/fio/${exp}_${mode}${label}_${pat}_${bs}_qd${qd}_mix${rwmix}_r${r}.json"
    FILENAME="$tgt" SIZE="$size" BS="$bs" RW="$rw" RWMIXREAD=$((rwmix*10)) QD="$qd" \
    RUNTIME="$(awk -v t="$rt" 'BEGIN{printf "%dms", t*1000}')" IOSIZE="$iosize" DIRECT="$direct" SEED=$((SEED + r)) \
      fio --output-format=json --output="$json" "$ROOT/fio/job.fio"
    "$ROOT/scripts/fio_to_csv.sh" $(hdr) "$exp" "$mode$label" "$pat" "$bs" "$qd" "$rwmix" "$r" "$(temp_now)" \
      < "$json" >> "$RAW"
  done
}

# ------------------------------------------------------------------ files
gate() { "$SAFE" "$1" "${2:-0}" || { echo "refusing to run" >&2; exit 1; }; }

# Sequential reads are only fast if the data was written sequentially (see `layout`):
# re-write the test file sequentially before every sequential-read group.
relayout() { precondition >/dev/null; }

precondition() {
  local bytes=$((FSIZE_MIB*MiB)) cur=0
  [ -f "$FILE" ] && cur=$(stat -c %s "$FILE")
  if [ "$cur" -ne "$bytes" ]; then rm -f -- "$FILE"; cur=0; fi
  gate "$FILE" $((bytes - cur + MARGIN))
  echo "preconditioning ${FSIZE_MIB} MiB test file (one sequential O_DIRECT pass, random fill)…"
  "$BLK" --file "$FILE" --precondition --size "$bytes" --bs $((1*MiB)) --qd 8 --seed "$SEED"
}

# Large file for working-set / sustained runs: refuse unless size + 10 GiB fits.
big_gate() {
  local bytes=$((SUSTAIN_GIB*GiB)) have=0 avail
  [ -f "$BIG" ] && have=$(stat -c %s "$BIG")
  avail=$(avail_bytes)
  if [ $((avail + have)) -lt $((bytes + MARGIN)) ]; then
    echo "SAFETY REFUSED: ${SUSTAIN_GIB} GiB large file needs $(( (bytes+MARGIN)/GiB )) GiB free" \
         "(file + 10 GiB margin); scratch fs has $(( (avail+have)/GiB )) GiB. Lower SUSTAIN_GIB." >&2
    exit 1
  fi
  gate "$BIG" 0
}

# ------------------------------------------------------------------ summaries
# summarize RAW OUT GROUP STATS : adds temp_c when the raw file has it (old runs do not).
summ() {
  local raw="$1" out="$2" group="$3" stats="$4"
  head -1 "$raw" | grep -q 'temp_c' && stats="$stats,temp_c"
  "$SUMMARIZE" --in "$raw" --out "$out" --group "$group" --stat "$stats"
}
P="$ROOT/data/processed"
sum_zero_queue()  { summ "$1" "$P/zero_queue.csv"  mode,pattern,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us; }
sum_block_size()  { summ "$1" "$P/block_size.csv"  bs,pattern,mode,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us; }
sum_rw_mix()      { summ "$1" "$P/rw_mix.csv"      rwmix,mode,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us; }
sum_tail()        { summ "$1" "$P/tail.csv"        qd,bs,pattern,mode lat_p50_us,lat_p95_us,lat_p99_us,lat_p999_us,iops,lat_mean_us; }
sum_pitfall()     { summ "$1" "$P/pitfall.csv"     mode,pattern,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us; }
sum_layout()      { summ "$1" "$P/layout.csv"      experiment,mode,pattern,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us; }
sum_working_set() { summ "$1" "$P/working_set.csv" span_gib,mode,qd,bs,pattern iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us,lat_p999_us; }
sum_queue_depth() {
  # Little's Law column L = IOPS x mean latency, per repetition, so it gets IQR too.
  local tmp; tmp="$(mktemp)"
  awk -F, 'NR==1{print $0",littles_l"; next} {print $0","($10*$12/1e6)}' "$1" > "$tmp"
  summ "$tmp" "$P/queue_depth.csv" qd,mode,bs,pattern iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us,lat_p999_us,littles_l
  rm -f "$tmp"
  knee "$P/queue_depth.csv" > "$P/queue_depth_knee.csv"
}
# Knee criterion: the smallest QD whose doubling raises median IOPS by < 10%.
knee() {
  awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i; next}
    {m=$c["mode"]; q=$c["qd"]+0; n[m]++; Q[m,n[m]]=q; I[m,n[m]]=$c["iops_median"]; W[m,n[m]]=$c["lat_mean_us_median"]; modes[m]=1}
    END{printf "mode,knee_qd,knee_iops,knee_lat_us,next_qd,gain_pct,max_iops\n";
      for(m in modes){k=-1; mx=0; for(j=1;j<=n[m];j++) if(I[m,j]>mx) mx=I[m,j];
        for(j=1;j<n[m];j++) if(Q[m,j+1]==2*Q[m,j] && I[m,j+1] < 1.10*I[m,j]) {k=j; break}
        if(k<0) printf "%s,NA,NA,NA,NA,NA,%.0f\n", m, mx;
        else printf "%s,%d,%.0f,%.1f,%d,%.1f,%.0f\n", m, Q[m,k], I[m,k], W[m,k], Q[m,k+1], 100*(I[m,k+1]/I[m,k]-1), mx}}' "$1"
}
# Join blkbench and fio medians point by point.
fio_compare() {
  awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i; next}
    {k=$c["mode"]","$c["pattern"]","$c["bs"]","$c["qd"]; keys[k]=1
     I[$c["experiment"],k]=$c["iops_median"]; P5[$c["experiment"],k]=$c["lat_p50_us_median"]; P9[$c["experiment"],k]=$c["lat_p99_us_median"]}
    END{print "mode,pattern,bs,qd,blk_iops,fio_iops,iops_ratio,blk_p50_us,fio_p50_us,blk_p99_us,fio_p99_us";
      for(k in keys) if((("blkbench",k) in I) && (("fio",k) in I))
        printf "%s,%.0f,%.0f,%.3f,%.1f,%.1f,%.1f,%.1f\n", k, I["blkbench",k], I["fio",k], I["fio",k]/I["blkbench",k],
               P5["blkbench",k], P5["fio",k], P9["blkbench",k], P9["fio",k]}' "$1" \
    | { read -r h; echo "$h"; sort -t, -k1,1 -k2,2 -k4,4n -k3,3n; }
}
# Sustained-write time series: add a global time axis and a one-row summary.
sum_sustained() {
  awk -F, 'BEGIN{OFS=","} NR==1{print $0,"t_global_s"; next}
    {if($2!=ph){off+=last; ph=$2} last=$8; print $0, off+$8}' "$1" > "$P/sustained.csv"
  # burst  = median of the leading seconds that stay >= 50% of the first second's rate
  # cliff  = first 5-s window whose median is < 50% of burst (GiB written just before it)
  # steady = median of the fill's last 30%; random phase = whole-phase average IOPS
  #          (bytes/time) plus per-second quartiles, since it alternates between states
  awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i; next}
    {ph=$c["phase"]; t=$c["temp_c"]+0; if(t>0){if(tmin==""||t<tmin)tmin=t; if(t>tmax)tmax=t}}
    ph=="seq_fill"{n++; F[n]=$c["mibps"]; G[n]=$c["gib_done"]; T[n]=$c["t_s"]; fill_gib=$c["gib_done"]; fill_s=$c["t_s"]}
    ph=="rand_steady"{r++; R[r]=$c["iops"]; RP[r]=$c["lat_p99_us"]; rgib=$c["gib_done"]; rsec=$c["t_s"]}
    ph=="recovery"{v++; V[v]=$c["mibps"]}
    function sorted(A,lo,hi,B,  i,m,k,j){m=0; for(i=lo;i<=hi;i++){B[++m]=A[i]+0}
      for(i=2;i<=m;i++){k=B[i]; j=i-1; while(j>0 && B[j]>k){B[j+1]=B[j]; j--} B[j+1]=k} return m}
    function q(A,lo,hi,p,  B,m,x,f){m=sorted(A,lo,hi,B); if(!m) return -1; x=1+p*(m-1); f=int(x);
      return (f>=m)?B[m]:B[f]+(x-f)*(B[f+1]-B[f])}
    END{
      nb=0; for(i=1;i<=n && F[i]>=0.5*F[1];i++) nb=i
      burst=q(F,1,nb,0.5)
      cliff_gib=-1; cliff_s=-1; ci=0
      for(i=1;i+4<=n;i++){ if(F[i] < 0.5*burst && q(F,i,i+4,0.5) < 0.5*burst){ci=i; cliff_gib=(i>1?G[i-1]:0); cliff_s=(i>1?T[i-1]:0); break} }
      # steady = median of the seconds after the cliff (all of them); without a cliff the
      # fill never left the cache, so steady is undefined (-1) and fill_gib is a lower bound
      steady=(ci>0?q(F,ci,n,0.5):-1)
      ravg=(rsec>0?rgib*1073741824/4096/rsec:-1)
      print "burst_mibps,burst_s,steady_mibps,steady_over_burst,cliff_gib,cliff_s,fill_gib,fill_s,fill_avg_mibps,rand_steady_iops,rand_iops_q25,rand_iops_q75,rand_steady_p99_us,recovery_mibps,recovery_late_mibps,temp_min_c,temp_max_c,cliff_found,cache_lower_bound_gib"
      printf "%.0f,%d,%.0f,%.3f,%.1f,%.0f,%.1f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f,%d,%.1f\n", burst, nb, steady,
        (burst>0&&steady>0?steady/burst:-1), cliff_gib, cliff_s, fill_gib, fill_s, (fill_s>0?fill_gib*1024/fill_s:0),
        ravg, q(R,1,r,0.25), q(R,1,r,0.75), q(RP,1,r,0.5), q(V,1,(v<5?v:5),0.5), q(V,(v>5?v-4:1),v,0.5), tmin, tmax,
        (ci>0), (ci>0?cliff_gib:fill_gib)}' \
    "$P/sustained.csv" > "$P/sustained_summary.csv"
}

# ------------------------------------------------------------------ experiments
exp_zero_queue() {
  start_experiment zero_queue
  blk --experiment zero_queue --bs 4096   --qd 1 --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  wgap
  blk --experiment zero_queue --bs 4096   --qd 1 --pattern rand --rwmix 0  --runtime "$RUNTIME" --reps "$REPS" --max-bytes "$WCAP"
  relayout   # the random writes above scatter the file's physical layout; restore it
  blk --experiment zero_queue --bs 131072 --qd 1 --pattern seq  --rwmix 10 --runtime "$RUNTIME" --reps "$REPS"
  wgap       # let the re-fill drain from the SLC cache before the sequential-write baseline
  blk --experiment zero_queue --bs 131072 --qd 1 --pattern seq  --rwmix 0  --runtime "$RUNTIME" --reps "$REPS" --max-bytes "$WCAP"
  end_experiment; sum_zero_queue "$RAW"
}

exp_block_size() {
  start_experiment block_size
  local bs p m q
  # QD=1: random and sequential, read and write; QD=32: random read, sequential read and write.
  for q in 1 32; do
    for p in rand seq; do
      [ "$p" = seq ] && relayout
      for m in 10 0; do
        [ "$q" = 32 ] && [ "$p" = rand ] && [ "$m" = 0 ] && continue
        for bs in 4096 16384 32768 65536 131072 262144 524288 1048576; do
          if [ "$m" = 0 ]; then
            wgap
            blk --experiment block_size --bs "$bs" --qd "$q" --pattern "$p" --rwmix 0 --runtime "$RUNTIME" --reps "$WREPS" --max-bytes "$WCAP" $(hdr)
          else
            blk --experiment block_size --bs "$bs" --qd "$q" --pattern "$p" --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
          fi
        done
      done
    done
  done
  end_experiment; sum_block_size "$RAW"
}

exp_rw_mix() {
  start_experiment rw_mix
  local m
  for m in 10 7 5 0; do
    if [ "$m" = 10 ]; then
      blk --experiment rw_mix --bs 4096 --qd 16 --pattern rand --rwmix "$m" --runtime "$RUNTIME" --reps "$REPS" $(hdr)
    else
      wgap
      blk --experiment rw_mix --bs 4096 --qd 16 --pattern rand --rwmix "$m" --runtime "$RUNTIME" --reps "$REPS" --max-bytes "$WCAP" $(hdr)
    fi
  done
  end_experiment; sum_rw_mix "$RAW"
}

exp_queue_depth() {
  start_experiment queue_depth
  local q
  for q in 1 2 4 8 16 32 64 128 256; do
    blk --experiment queue_depth --bs 4096 --qd "$q" --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  done
  for q in 1 2 4 8 16 32 64 128 256; do
    wgap
    blk --experiment queue_depth --bs 4096 --qd "$q" --pattern rand --rwmix 0 --runtime "$RUNTIME" --reps "$REPS" --max-bytes "$WCAP" $(hdr)
  done
  end_experiment; sum_queue_depth "$RAW"
}

exp_tail() {
  start_experiment tail
  local q
  # mid QD (8), the two QDs bracketing the knee (32, 64) and one past it (128); longer runs.
  for q in 8 32 64 128; do
    blk --experiment tail --bs 4096 --qd "$q" --pattern rand --rwmix 10 --runtime "$(awk -v t="$RUNTIME" 'BEGIN{print t+2}')" --reps "$REPS" $(hdr)
  done
  end_experiment; sum_tail "$RAW"
}

exp_pitfall() {
  start_experiment pitfall
  # Pitfall: buffered (page-cache) vs direct I/O over the SAME 64 MiB region,
  # 4 KiB sequential reads. Same knobs; only the cache bypass differs.
  local span=$((64*MiB))
  blk --experiment pitfall --bs 4096 --qd 1 --pattern seq --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$REPS" $(hdr)
  blk --experiment pitfall --bs 4096 --qd 1 --pattern seq --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "$REPS" --buffered
  end_experiment; sum_pitfall "$RAW"
}

# layout: the same 128 KiB QD1 sequential read after (a) a sequential fill and (b) a
# 4 KiB random overwrite of 2x the file (~86% of blocks rewritten in random order).
# Insufficient/inappropriate preconditioning changes "sequential" read speed.
exp_layout() {
  start_experiment layout
  local state
  for state in seq_filled rand_overwritten; do
    if [ "$state" = rand_overwritten ]; then
      "$BLK" --file "$FILE" --seed "$SEED" --bs 4096 --qd 32 --pattern rand --rwmix 0 \
             --runtime 600 --reps 1 --max-bytes $((2*FSIZE_MIB*MiB)) >> "$RAWDIR/overwrite.csv"
    fi
    blk --experiment "layout_$state" --bs 131072 --qd 1  --pattern seq --rwmix 10 --runtime "$RUNTIME" --reps "$REPS" $(hdr)
    blk --experiment "layout_$state" --bs 131072 --qd 32 --pattern seq --rwmix 10 --runtime "$RUNTIME" --reps "$REPS"
    blk --experiment "layout_$state" --bs 4096   --qd 1  --pattern rand --rwmix 10 --runtime "$RUNTIME" --reps "$REPS"
  done
  end_experiment; sum_layout "$RAW"
}

exp_fio_check() {
  if ! have_fio; then
    echo "[fio_check] SKIPPED: fio is not installed (install it, e.g. 'pacman -S fio', then rerun)."
    return 0
  fi
  local name="${FIO_EXP_NAME:-fio_check}" nrep="${FIO_REPS:-$REPS}"
  start_experiment "$name"
  echo "# fio: $(fio --version)" >> "$RAWDIR/env.txt"
  local saved="$ENGINE" pt bs q p m cap r
  # bs qd pattern rwmix — QD=1 baselines plus a deep-queue read and write point
  # reads first; the caller preconditions the file right before this experiment (in the
  # 20261021 `all` run it did not, so its sequential points measured layout's scattered file).
  # Engine order alternates per repetition (even r: blkbench first; odd r: fio first) so
  # drive-state effects from the preceding write can be separated from engine effects;
  # raw_order.csv tags each row with its engine and position.
  local ord="$RAWDIR/raw_order.csv" one="$RAWDIR/one.tmp" e first second
  local points="${FIO_POINTS:-131072 1 seq 10;131072 32 seq 10;4096 1 rand 10;4096 32 rand 10;131072 1 seq 0;4096 1 rand 0;4096 32 rand 0}"
  local IFS_save="$IFS" ptlist; IFS=';' read -r -a ptlist <<< "$points"; IFS="$IFS_save"
  for pt in "${ptlist[@]}"; do
    read -r bs q p m <<< "$pt"
    cap=(); [ "$m" = 0 ] && { cap=(--max-bytes "$WCAP"); wgap; }
    for ((r=0; r<nrep; r++)); do      # interleave the engines rep by rep, alternating order
      if (( r % 2 == 0 )); then first=blkbench; second=fio; else first=fio; second=blkbench; fi
      for e in "$first" "$second"; do
        : > "$one"
        ENGINE=$e RAW="$one" blk --experiment "$e" --bs "$bs" --qd "$q" --pattern "$p" --rwmix "$m" --runtime "$RUNTIME" --reps 1 "${cap[@]}" --header
        [ -s "$RAW" ] || head -1 "$one" > "$RAW"
        [ -s "$ord" ] || head -1 "$one" > "$ord"
        tail -n +2 "$one" >> "$RAW"
        tail -n +2 "$one" | awk -F, -v OFS=, -v pos="$([ "$e" = "$first" ] && echo 1st || echo 2nd)" '{$1=$1"_"pos; print}' >> "$ord"
      done
    done
  done
  ENGINE="$saved"
  end_experiment
  rm -f "$one"
  if [ "$name" = fio_check ]; then
    summ "$RAW" "$P/fio_check.csv" experiment,mode,pattern,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us
    fio_compare "$P/fio_check.csv" > "$P/fio_compare.csv"
    summ "$ord" "$P/fio_order.csv" experiment,mode,pattern,bs,qd iops,lat_p50_us,lat_p99_us
  else
    sum_with_lean fio_check          # merge the partial (lean) run into the full one
  fi
  cat "$P/fio_compare.csv"
}

# ---- large-file device-state experiments --------------------------------------
# sustained: create the large file and write it ONCE sequentially (128 KiB, QD32),
# logging throughput / latency / temperature every second -> SLC-cache cliff;
# then a time- and byte-capped 4 KiB random-write phase (steady state), an idle
# gap logged for temperature only, and a short recovery burst.
exp_sustained() {
  local keep="${1:-0}"
  big_gate
  rm -f -- "$BIG"
  start_experiment sustained
  echo "# SUSTAIN_GIB=$SUSTAIN_GIB SUSTAIN_MAX_S=$SUSTAIN_MAX_S RAND_S=$RAND_S RAND_CAP_GIB=$RAND_CAP_GIB IDLE_S=$IDLE_S RECOVER_S=$RECOVER_S RECOVER_CAP_GIB=$RECOVER_CAP_GIB" >> "$RAWDIR/env.txt"
  local i
  # baseline temperature, idle
  echo "experiment,phase,mode,pattern,bs,qd,rwmix,t_s,gib_done,ios,iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us,lat_p999_us,lat_max_us,temp_c" > "$RAW"
  for ((i=1; i<=10; i++)); do sleep 1; echo "sustained,idle_pre,none,none,0,0,0,$i,0,0,0,0,0,0,0,0,0,$(temp_now)" >> "$RAW"; done
  # STOP_BELOW (e.g. 0.3): stop the fill STOP_HOLD s after throughput falls below that
  # fraction of the first-5-s burst median (stop-at-cliff); 0 = write the whole file.
  local stop=(); [ "${STOP_BELOW:-0}" != 0 ] && stop=(--stop-below "$STOP_BELOW" --stop-hold "${STOP_HOLD:-10}" --burst-intervals 5)
  echo "# STOP_BELOW=${STOP_BELOW:-0} STOP_HOLD=${STOP_HOLD:-10}" >> "$RAWDIR/env.txt"
  echo "  seq_fill: up to ${SUSTAIN_GIB} GiB sequential write (time cap ${SUSTAIN_MAX_S}s${stop:+, stop at cliff})…"
  "$BLK" --file "$BIG" --precondition --size $((SUSTAIN_GIB*GiB)) --bs 131072 --qd 32 --seed "$SEED" \
         --interval 1 --runtime "$SUSTAIN_MAX_S" --experiment sustained --phase seq_fill "${stop[@]}" "${TEMP_ARGS[@]}" >> "$RAW"
  # random phase only over the part of the file the fill actually wrote
  local wspan; wspan=$(awk -F, '$2=="seq_fill"{g=$9} END{printf "%d", g*1073741824/1048576}' "$RAW")
  wspan=$(( wspan / 4 * 4 * MiB )); [ "$wspan" -ge $((64*MiB)) ] || wspan=$((64*MiB))
  echo "  rand_steady: 4 KiB random write QD32, ${RAND_S}s or ${RAND_CAP_GIB} GiB…"
  "$BLK" --file "$BIG" --bs 4096 --qd 32 --pattern rand --rwmix 0 --seed "$SEED" --interval 1 --span "$wspan" \
         --runtime "$RAND_S" --max-bytes $((RAND_CAP_GIB*GiB)) --experiment sustained --phase rand_steady "${TEMP_ARGS[@]}" >> "$RAW"
  echo "  idle: ${IDLE_S}s…"
  for ((i=1; i<=IDLE_S; i++)); do sleep 1; echo "sustained,idle,none,none,0,0,0,$i,0,0,0,0,0,0,0,0,0,$(temp_now)" >> "$RAW"; done
  echo "  recovery: 128 KiB sequential write QD32, ${RECOVER_S}s or ${RECOVER_CAP_GIB} GiB…"
  "$BLK" --file "$BIG" --bs 131072 --qd 32 --pattern seq --rwmix 0 --seed "$SEED" --interval 1 \
         --runtime "$RECOVER_S" --max-bytes $((RECOVER_CAP_GIB*GiB)) --experiment sustained --phase recovery "${TEMP_ARGS[@]}" >> "$RAW"
  end_experiment
  sum_sustained "$RAW"
  cat "$P/sustained_summary.csv"
  [ "$keep" = 1 ] || { [ "$KEEP_SCRATCH" = 1 ] || rm -f -- "$BIG"; }
}

# working_set: 4 KiB random read (QD1, QD32) and write (QD32, byte-capped) over
# growing LBA spans of the large file (FTL-mapping / HMB locality).
exp_working_set() {
  local need_fill=1 span g
  big_gate
  [ -f "$BIG" ] && [ "$(stat -c %s "$BIG")" -eq $((SUSTAIN_GIB*GiB)) ] && [ "${BIG_FILLED:-0}" = 1 ] && need_fill=0
  if [ "$need_fill" = 1 ]; then
    rm -f -- "$BIG"
    echo "[working_set] preconditioning ${SUSTAIN_GIB} GiB large file (one sequential pass)…"
    "$BLK" --file "$BIG" --precondition --size $((SUSTAIN_GIB*GiB)) --bs $((1*MiB)) --qd 8 --seed "$SEED"
  fi
  start_experiment working_set
  echo "# spans (GiB): $WS_LIST_GIB of a ${SUSTAIN_GIB} GiB file" >> "$RAWDIR/env.txt"
  local tmp="$RAWDIR/ws.tmp" order="$WS_LIST_GIB" r
  # WS_REVERSE=1: a second pass in reverse span order, so span is not confounded with time
  if [ "${WS_REVERSE:-0}" = 1 ]; then
    order="$WS_LIST_GIB $(echo $WS_LIST_GIB | tr ' ' '\n' | tac | tr '\n' ' ')"; fi
  echo "# span order: $order (reps per pass: ${WS_REPS:-$REPS})" >> "$RAWDIR/env.txt"
  for g in $order; do
    [ "$g" -le "$SUSTAIN_GIB" ] || { echo "  skip span ${g} GiB > SUSTAIN_GIB" >&2; continue; }
    span=$((g*GiB))
    : > "$tmp"
    TARGET="$BIG" RAW="$tmp" blk --experiment working_set --bs 4096 --qd 1  --pattern rand --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "${WS_REPS:-$REPS}" --header
    TARGET="$BIG" RAW="$tmp" blk --experiment working_set --bs 4096 --qd 32 --pattern rand --rwmix 10 --span "$span" --runtime "$RUNTIME" --reps "${WS_REPS:-$REPS}"
    TARGET="$BIG" RAW="$tmp" blk --experiment working_set --bs 4096 --qd 32 --pattern rand --rwmix 0  --span "$span" --runtime "$RUNTIME" --reps "${WS_REPS:-$REPS}" --max-bytes "$WCAP"
    # prepend the span column
    awk -F, -v g="$g" -v first="$([ -s "$RAW" ] && echo 0 || echo 1)" \
      'NR==1{ if(first) print "span_gib,"$0; next} {print g","$0}' "$tmp" >> "$RAW"
  done
  rm -f "$tmp"
  end_experiment
  sum_working_set "$RAW"
  [ "$KEEP_SCRATCH" = 1 ] || rm -f -- "$BIG"
}

exp_device_state() {
  # sustained fill doubles as the large file's preconditioning pass for working_set
  exp_sustained 1
  BIG_FILLED=1 exp_working_set
}

# ------------------------------------------------------------------ reprocess / plan
latest_raw() { { ls -d "$ROOT/data/raw/$1"/*/ 2>/dev/null || true; } | sort | tail -1; }
# merge_lean OLD NEW: OLD with every configuration (experiment,mode,pattern,bs,qd,rwmix) that
# NEW re-measured replaced IN PLACE by NEW's rows (so sweep order, and hence plot lines and
# the knee rule, are preserved); configurations only in NEW are appended. Used when a lean
# re-run repeats only part of an experiment (block_size_lean, queue_depth_lean, fio_check_lean).
merge_lean() {
  awk -F, 'FNR==1{ if(NR==1){for(i=1;i<=NF;i++)c[$i]=i; print}; next }
    function k(){return $c["experiment"]","$c["mode"]","$c["pattern"]","$c["bs"]","$c["qd"]","$c["rwmix"]}
    NR==FNR{ old[++n]=$0; ok[n]=k(); next }
    { kk=k(); if(!(kk in cnt)) order[++nk]=kk; rows[kk, ++cnt[kk]]=$0 }
    END{ for(i=1;i<=n;i++){ kk=ok[i]
           if(kk in cnt){ if(!(kk in done)){ for(j=1;j<=cnt[kk];j++) print rows[kk,j]; done[kk]=1 } }
           else print old[i] }
         for(i=1;i<=nk;i++) if(!(order[i] in done)) for(j=1;j<=cnt[order[i]];j++) print rows[order[i],j] }' "$1" "$2"
}
# summarize an experiment, merging the newest *_lean run into the newest full run if present
sum_with_lean() {
  local e="$1" d l tmp; d="$(latest_raw "$e")"; l="$(latest_raw "${e}_lean")"
  [ -n "$d" ] && [ -s "$d/raw.csv" ] || { [ -n "$l" ] && d="$l" || return 0; }
  # a lean run only patches the full run it followed; a newer full run supersedes it
  if [ -n "$l" ] && [ -s "$l/raw.csv" ] && [ "$l" != "$d" ] && [[ "$(basename "$l")" > "$(basename "$d")" ]]; then
    tmp="$(mktemp)"; merge_lean "$d/raw.csv" "$l/raw.csv" > "$tmp"
    echo "reprocess $e <- $d + $l (lean rows replace matching configurations)"
  else tmp="$(mktemp)"; cp "$d/raw.csv" "$tmp"; echo "reprocess $e <- $d"; fi
  if [ "$e" = fio_check ]; then
    summ "$tmp" "$P/fio_check.csv" experiment,mode,pattern,bs,qd iops,mibps,lat_mean_us,lat_p50_us,lat_p99_us
    fio_compare "$P/fio_check.csv" > "$P/fio_compare.csv"
    local o; for o in "$l/raw_order.csv" "$d/raw_order.csv"; do
      [ -s "$o" ] && { summ "$o" "$P/fio_order.csv" experiment,mode,pattern,bs,qd iops,lat_p50_us,lat_p99_us; break; }; done
  else "sum_$e" "$tmp"; fi
  rm -f "$tmp"
}

reprocess() {
  local e d
  for e in zero_queue rw_mix tail pitfall layout working_set sustained; do
    d="$(latest_raw "$e")"; [ -n "$d" ] && [ -s "$d/raw.csv" ] || continue
    echo "reprocess $e <- $d"; "sum_$e" "$d/raw.csv"
  done
  for e in block_size queue_depth fio_check; do sum_with_lean "$e"; done
}

dryrun() {
  device_report
  echo "# scratch avail: $(( $(avail_bytes) / GiB )) GiB; large file ${SUSTAIN_GIB} GiB + 10 GiB margin required"
  echo "# engine=$ENGINE fio=$(have_fio && fio --version || echo absent)"
  "$SAFE" "$FILE" $((FSIZE_MIB*MiB + MARGIN))
  "$SAFE" "$BIG" 0
}

main() {
  local what="${1:-all}"
  case "$what" in reprocess) need; mkdir -p "$P"; reprocess; return;; dryrun) dryrun; return;; esac
  need
  mkdir -p "$P" "$SCRATCH"
  trap cleanup EXIT
  case "$what" in
    zero_queue)   precondition; exp_zero_queue ;;
    block_size)   precondition; exp_block_size ;;
    rw_mix)       precondition; exp_rw_mix ;;
    queue_depth)  precondition; exp_queue_depth ;;
    tail)         precondition; exp_tail ;;
    pitfall)      precondition; exp_pitfall ;;
    layout)       precondition; exp_layout ;;
    fio_check)    if have_fio; then precondition; fi; exp_fio_check ;;
    sustained)    exp_sustained ;;
    working_set)  exp_working_set ;;
    device_state) exp_device_state ;;
    all) # every experiment starts from a freshly preconditioned (sequentially re-written) file
         local e
         for e in zero_queue block_size rw_mix queue_depth tail pitfall layout fio_check; do
           precondition; "exp_$e"
         done
         echo "note: the large-file device-state runs are separate: scripts/run.sh device_state" ;;
    *) echo "unknown experiment: $what" >&2
       echo "usage: $0 {zero_queue|block_size|rw_mix|queue_depth|tail|pitfall|layout|fio_check|sustained|working_set|device_state|all|reprocess|dryrun}" >&2; exit 2 ;;
  esac
  echo "done: $what"
}
# RUN_SH_LIB=1: only define the functions (scripts/rerun_clean.sh sources this file)
[ "${RUN_SH_LIB:-0}" = 1 ] || main "$@"
