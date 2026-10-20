#!/usr/bin/env bash
# safety.sh — refuse to benchmark anything that could hold valuable data.
#
#   scripts/safety.sh <target-file> [min_free_bytes]
#
# The project spec warns: never benchmark a partition with valuable data; use a
# dedicated empty partition, a reserved raw device, or a large disposable file
# with direct I/O. This repo only ever uses the last, safest option. This gate is
# called before any run and HARD-REFUSES anything that is not a plain disposable
# file inside the project's own data/scratch/ directory:
#   - must NOT be a block device or character device;
#   - must NOT be a mountpoint or sit at the root of a mount;
#   - must live under <project>/data/scratch/ (a dedicated scratch dir);
#   - must be a regular file (or absent, to be created there);
#   - the filesystem must have enough free space.
# Exits non-zero (refuses) otherwise.
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
# Scratch directory may be relocated to another device via ACS_SCRATCH (see run.sh);
# the gate below is identical whatever the location (plain file inside it, never a
# device/partition/mountpoint).
SCRATCH="${ACS_SCRATCH:-$PROJ/data/scratch}"
target="${1:-}"
min_free="${2:-0}"

die() { echo "SAFETY REFUSED: $*" >&2; exit 1; }
[ -n "$target" ] || die "no target given"

# Resolve to an absolute path without requiring the file to exist yet.
abs="$(readlink -f -- "$target" 2>/dev/null || echo "$target")"
case "$abs" in /*) : ;; *) abs="$PWD/$abs" ;; esac

# 1. Never a device node.
[ -b "$abs" ] && die "'$abs' is a BLOCK device"
[ -c "$abs" ] && die "'$abs' is a CHARACTER device"

# 2. Must be inside the dedicated scratch directory.
scratch_abs="$(readlink -f -- "$SCRATCH" 2>/dev/null || echo "$SCRATCH")"
case "$abs" in
  "$scratch_abs"/*) : ;;
  *) die "'$abs' is outside the dedicated scratch dir ($scratch_abs)";;
esac

# 3. Never a mountpoint.
if mountpoint -q -- "$abs" 2>/dev/null; then die "'$abs' is a mountpoint"; fi

# 4. If it exists, it must be a regular file.
if [ -e "$abs" ] && [ ! -f "$abs" ]; then die "'$abs' exists and is not a regular file"; fi

# 5. Enough free space on the scratch filesystem.
mkdir -p "$scratch_abs"
avail=$(df -B1 --output=avail "$scratch_abs" | tail -1 | tr -d ' ')
if [ "$min_free" -gt 0 ] 2>/dev/null && [ "${avail:-0}" -lt "$min_free" ]; then
  die "only ${avail} bytes free, need ${min_free}"
fi

echo "safety OK: disposable file '$abs' (scratch fs has ${avail} bytes free)"
exit 0
