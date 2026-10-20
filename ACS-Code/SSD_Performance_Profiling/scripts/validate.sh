#!/usr/bin/env bash
# validate.sh — safety + sanity checks for Project 3 (make-style gate).
#
# 1. safety.sh must REFUSE a block device, a path outside data/scratch/, and a
#    mountpoint, and ACCEPT a disposable file inside data/scratch/.
# 2. blkbench on a small preconditioned file must produce physically sane numbers:
#    sequential 128 KiB throughput > random 4 KiB throughput, and QD>1 keeps more
#    requests in flight than QD=1 (Little's Law: IOPS*latency grows with QD).
# Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BLK="$ROOT/build/blkbench"
SAFE="$ROOT/scripts/safety.sh"
SCRATCH="$ROOT/data/scratch"
[ -x "$BLK" ] || { echo "missing $BLK; run make" >&2; exit 1; }
fail=0
ok()   { echo "  OK: $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

echo "safety.sh refusals:"
"$SAFE" /dev/sda >/dev/null 2>&1 && bad "accepted /dev/sda (block device!)" || ok "refused /dev/sda"
"$SAFE" /etc/passwd >/dev/null 2>&1 && bad "accepted /etc/passwd (outside scratch!)" || ok "refused /etc/passwd"
"$SAFE" / >/dev/null 2>&1 && bad "accepted / (mountpoint!)" || ok "refused /"
mkdir -p "$SCRATCH"
"$SAFE" "$SCRATCH/vtest.bin" >/dev/null 2>&1 && ok "accepted scratch file" || bad "rejected a valid scratch file"

echo "blkbench sanity (64 MiB scratch file):"
F="$SCRATCH/vtest.bin"
dd if=/dev/zero of="$F" bs=1M count=64 status=none
"$BLK" --file "$F" --precondition --bs 1048576 >/dev/null 2>&1
rnd=$("$BLK" --file "$F" --bs 4096   --qd 1 --pattern rand --rwmix 10 --runtime 2 --reps 1 | awk -F, '{print $11}')
seq=$("$BLK" --file "$F" --bs 131072 --qd 1 --pattern seq  --rwmix 10 --runtime 2 --reps 1 | awk -F, '{print $11}')
l1=$("$BLK"  --file "$F" --bs 4096   --qd 1  --pattern rand --rwmix 10 --runtime 2 --reps 1 | awk -F, '{print $10*$12}')
l8=$("$BLK"  --file "$F" --bs 4096   --qd 8  --pattern rand --rwmix 10 --runtime 2 --reps 1 | awk -F, '{print $10*$12}')
echo "  seq MiB/s=$seq  rand MiB/s=$rnd  (IOPS*lat) QD1=$l1 QD8=$l8"
awk "BEGIN{exit !($seq > $rnd)}" && ok "sequential throughput > random" || bad "sequential !> random"
awk "BEGIN{exit !($l8 > $l1)}"   && ok "concurrency grows with QD (Little's Law)" || bad "QD8 concurrency !> QD1"
rm -f "$F"

[ "$fail" -eq 0 ] && echo "all P3 safety/sanity checks passed" || { echo "P3 VALIDATION FAILED" >&2; exit 1; }
