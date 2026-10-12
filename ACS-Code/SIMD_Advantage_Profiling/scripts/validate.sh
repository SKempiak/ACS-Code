#!/usr/bin/env bash
# validate.sh — correctness validation for every build variant (make test).
#
# Two independent checks for each variant (scalar, autovec, native):
#   1. Reference comparison: the driver validates each kernel's output against
#      src/reference.c (compiled scalar, FP-contraction off) before timing, and
#      exits non-zero on any mismatch beyond tolerance. We sweep kernels, data
#      types, sizes with and without vector-width remainders, misaligned starts,
#      strides and the gather pattern.
#   2. Known-answer self-test (--selftest): checks independent of the reference
#      (dot of all-ones == N, etc.).
# Exits non-zero if any case fails.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VARIANTS=(scalar autovec native)
CPU_PIN="${CPU_PIN:-2}"
fail=0
cases=0

# quick validation run: validate() runs before timing; --min-ms 0 -> 1 iter.
check() { # <variant> <args...>
  local v="$1"; shift
  cases=$((cases + 1))
  if ! "$ROOT/build/$v/simd_bench" --cpu "$CPU_PIN" --reps 1 --min-ms 0 "$@" >/dev/null; then
    echo "FAIL [$v] $*" >&2
    fail=$((fail + 1))
  fi
}

for v in "${VARIANTS[@]}"; do
  [ -x "$ROOT/build/$v/simd_bench" ] || { echo "missing build/$v/simd_bench; run make" >&2; exit 1; }

  # known-answer self-test
  cases=$((cases + 1))
  "$ROOT/build/$v/simd_bench" --selftest >/dev/null || { echo "FAIL [$v] selftest" >&2; fail=$((fail + 1)); }

  # reference comparison over the knob matrix
  for k in saxpy dot mul stencil; do
    for dt in f32 f64; do
      # sizes with and without a vector-width remainder (8 f32 lanes / 4 f64 lanes)
      for n in 1 2 3 7 8 9 15 16 17 31 33 64 127 1000 1024 4095 4096 4097 65536; do
        check "$v" --kernel "$k" --dtype "$dt" --n "$n"
      done
    done
  done
  # int32 multiply
  for n in 1 7 16 17 1000 4096 4097; do check "$v" --kernel mul --dtype i32 --n "$n"; done

  # misaligned starts (bytes), float32 SAXPY
  for off in 4 8 12 16 20 28 32 60; do check "$v" --kernel saxpy --dtype f32 --n 4096 --offset "$off"; done

  # strided SAXPY
  for s in 2 4 8 16; do for n in 17 1000 4096 65536; do check "$v" --access stride --stride "$s" --n "$n"; done; done

  # gather SAXPY
  for n in 7 16 17 1000 4096 65536; do check "$v" --access gather --n "$n"; done
done

echo "validate: $((cases - fail))/$cases cases passed across ${VARIANTS[*]}"
[ "$fail" -eq 0 ] || { echo "VALIDATION FAILED: $fail case(s)" >&2; exit 1; }
echo "all correctness checks passed"
