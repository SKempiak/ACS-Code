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
# Exits non-zero if any case fails. Each passing reference comparison also logs
# its maximum relative error (ACS_REPORT_ERR); the largest per variant and data
# type is printed at the end (int32 must match exactly, i.e. error 0).
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VARIANTS=(scalar autovec native)
CPU_PIN="${CPU_PIN:-2}"
fail=0
cases=0
ERRLOG="$(mktemp)"; ERRTMP="$(mktemp)"; trap 'rm -f "$ERRLOG" "$ERRTMP"' EXIT

# quick validation run: validate() runs before timing; --min-ms 0 -> 1 iter.
check() { # <variant> <args...>
  local v="$1"; shift
  cases=$((cases + 1))
  local rc=0
  ACS_REPORT_ERR=1 "$ROOT/build/$v/simd_bench" --cpu "$CPU_PIN" --reps 1 --min-ms 0 "$@" \
    >/dev/null 2>"$ERRTMP" || rc=$?
  grep '^validate-err,' "$ERRTMP" >> "$ERRLOG"
  grep -v '^validate-err,' "$ERRTMP" >&2
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$v] $*" >&2
    fail=$((fail + 1))
  fi
}

for v in "${VARIANTS[@]}"; do
  start=$cases
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

  # explicit AVX2 gather (vgatherdps): only built into the AVX2+FMA variant
  if "$ROOT/build/$v/simd_bench" --info | grep -q '^gather_avx2=yes'; then
    for n in 7 8 9 16 17 1000 4096 65536; do check "$v" --access gather_avx2 --n "$n"; done
  fi
  echo "validate [$v]: $((cases - start)) cases"
done

echo "validate: $((cases - fail))/$cases cases passed across ${VARIANTS[*]}"
echo "max relative error vs reference (passing cases):"
#   validate-err,<variant>,<kernel>,<dtype>,<n>,<access>,<stride>,<offset>,<max_err>
awk -F, '{ kern = ($6 == "unit") ? $3 : "saxpy-" $6; k = sprintf("%-8s %-18s %s", $2, kern, $4)
           if (!(k in m) || $9 + 0 > m[k] + 0) { m[k] = $9; w[k] = "n=" $5 " offset=" $8 } }
         END { for (k in m) printf "  %s  %s  (%s)\n", k, m[k], w[k] }' "$ERRLOG" | sort
[ "$fail" -eq 0 ] || { echo "VALIDATION FAILED: $fail case(s)" >&2; exit 1; }
echo "all correctness checks passed"
