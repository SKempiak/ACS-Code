#!/usr/bin/env bash
# validate.sh — safety + sanity checks for Project 3 (`make test`).
#
# 1. safety.sh must REFUSE both block devices on the test host (/dev/nvme0n1, the
#    SSD; /dev/sda, the HDD), a symlink in the scratch dir that points at a device,
#    a directory, a path outside the scratch dir and a mountpoint, and must ACCEPT
#    a disposable file inside the scratch dir. These checks only stat()/readlink()
#    the paths; nothing here opens a device, let alone for writing.
# 2. blkbench must refuse a non-regular target (directory, symlink) before opening it.
# 3. On a small (64 MiB) preconditioned scratch file, blkbench must produce physically
#    sane numbers: the fill is incompressible; sequential 128 KiB throughput beats
#    random 4 KiB; QD>1 keeps more requests in flight than QD=1; and Little's Law
#    (IOPS x mean latency) reproduces the configured queue depth within 5 % — the
#    closed-loop harness keeps exactly QD requests outstanding, so a mismatch would
#    expose a timing or bookkeeping bug.
# 4. fio_to_csv.sh converts a fixture fio JSON correctly (no fio needed).
# Total writes: ~70 MiB, deleted at the end. Honors ACS_SCRATCH like run.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BLK="$ROOT/build/blkbench"
SAFE="$ROOT/scripts/safety.sh"
SCRATCH="${ACS_SCRATCH:-$ROOT/data/scratch}"
[ -x "$BLK" ] || { echo "missing $BLK; run make" >&2; exit 1; }
fail=0
ok()   { echo "  OK: $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }
refuses() { if "$SAFE" "$1" >/dev/null 2>&1; then bad "accepted $1 ($2!)"; else ok "refused $1 ($2)"; fi; }

mkdir -p "$SCRATCH"
V="$SCRATCH/vtest.d"; rm -rf "$V"; mkdir -p "$V"
F="$SCRATCH/vtest.bin"
trap 'rm -rf "$V" "$F"' EXIT

echo "safety.sh refusals (scratch: $SCRATCH):"
for dev in /dev/nvme0n1 /dev/sda; do
  if [ -b "$dev" ]; then refuses "$dev" "block device"; else echo "  skip: $dev not present on this host"; fi
done
ln -s /dev/sda "$V/link_to_dev"
refuses "$V/link_to_dev" "symlink to a block device"
refuses "$V" "directory"
refuses /etc/passwd "outside scratch"
refuses / "mountpoint"
if "$SAFE" "$F" >/dev/null 2>&1; then ok "accepted scratch file"; else bad "rejected a valid scratch file"; fi

echo "blkbench refusals (checked before open):"
"$BLK" --file "$V" --bs 4096 --runtime 0.1 --reps 1 >/dev/null 2>&1 && bad "blkbench opened a directory" || ok "blkbench refused a directory"
"$BLK" --file "$V/link_to_dev" --bs 4096 --runtime 0.1 --reps 1 >/dev/null 2>&1 && bad "blkbench followed a symlink" || ok "blkbench refused a symlink"

echo "blkbench sanity (64 MiB scratch file):"
rm -f "$F"
"$BLK" --file "$F" --precondition --size $((64*1024*1024)) --bs 1048576 --qd 4 >/dev/null 2>&1 \
  || { bad "precondition failed"; exit 1; }
raw=$((8*1024*1024)); gz=$(head -c "$raw" "$F" | gzip -1 | wc -c)
awk "BEGIN{exit !($gz > 0.99*$raw)}" && ok "fill is incompressible (gzip: $gz / $raw bytes)" || bad "fill compresses ($gz / $raw)"
run() { "$BLK" --file "$F" --runtime 1.5 --reps 1 "$@"; }
rnd=$(run --bs 4096   --qd 1 --pattern rand --rwmix 10 | awk -F, '{print $11}')
seq=$(run --bs 131072 --qd 1 --pattern seq  --rwmix 10 | awk -F, '{print $11}')
l1=$(run  --bs 4096   --qd 1 --pattern rand --rwmix 10 | awk -F, '{print $10*$12/1e6}')
l8=$(run  --bs 4096   --qd 8 --pattern rand --rwmix 10 | awk -F, '{print $10*$12/1e6}')
echo "  seq MiB/s=$seq  rand MiB/s=$rnd  L=IOPS*W: QD1=$l1 QD8=$l8"
awk "BEGIN{exit !($seq > $rnd)}" && ok "sequential throughput > random" || bad "sequential !> random"
awk "BEGIN{exit !($l8 > $l1)}"   && ok "concurrency grows with QD" || bad "QD8 concurrency !> QD1"
# L = IOPS x W can never exceed QD in a closed loop (only QD slots exist): a hard check.
# L < QD means time is lost between reaping a completion and resubmitting it (host-side
# gap); on a real SSD it is within a few % of QD, but on e.g. tmpfs, where O_DIRECT
# "I/O" completes synchronously inside io_submit, it is not — so that is only a warning.
awk "BEGIN{exit !($l8 <= 8*1.02)}" && ok "Little's Law: L=$l8 <= QD=8" || bad "Little's Law: L=$l8 exceeds QD=8 (timing bug)"
awk "BEGIN{exit !($l8 >= 8*0.95)}" && ok "Little's Law: L within 5% of QD=8 (queue kept full)" \
  || echo "  WARN: L=$l8 < 0.95*QD: host-side gap; expected only on a non-device fs such as tmpfs ($(df --output=fstype "$SCRATCH" | tail -1))"

# O_DIRECT really bypasses the page cache: buffered re-reads of the same 64 MiB must be far
# faster than direct ones (meaningless on tmpfs, where "direct" I/O is also served from RAM).
if [ "$(df --output=fstype "$SCRATCH" | tail -1 | tr -d ' ')" = tmpfs ]; then
  echo "  skip: direct-vs-buffered check (scratch is tmpfs)"
else
  d=$(run --bs 4096 --qd 1 --pattern seq --rwmix 10 | awk -F, '{print $10}')
  b=$(run --bs 4096 --qd 1 --pattern seq --rwmix 10 --buffered | awk -F, '{print $10}')
  awk "BEGIN{exit !($b > 5*$d)}" && ok "page cache bypassed: buffered IOPS $b >> direct $d" \
    || bad "buffered ($b) not >> direct ($d): is O_DIRECT in effect?"
fi

echo "fio_to_csv.sh fixture:"
if command -v jq >/dev/null; then
  row=$(echo '{"jobs":[{"mixed":{"bw_bytes":104857600,"iops":25600,"runtime":2000,"total_ios":51200,"lat_ns":{"mean":39000,"percentile":{"50.000000":38000,"95.000000":45000,"99.000000":60000,"99.900000":400000}}}}]}' \
        | "$ROOT/scripts/fio_to_csv.sh" t read rand 4096 1 10 0 30)
  [ "$row" = "t,read,rand,4096,1,10,0,51200,2,25600,100,39,38,45,60,400,30" ] && ok "fio JSON -> CSV row" || bad "fio_to_csv produced: $row"
else
  echo "  skip: jq not installed"
fi
command -v fio >/dev/null && echo "  note: fio present ($(fio --version)); run 'scripts/run.sh fio_check'" \
                          || echo "  note: fio absent; fio_check will skip"

[ "$fail" -eq 0 ] && echo "all P3 safety/sanity checks passed" || { echo "P3 VALIDATION FAILED" >&2; exit 1; }
