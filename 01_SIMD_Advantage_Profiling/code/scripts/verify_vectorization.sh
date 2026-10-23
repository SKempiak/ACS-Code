#!/usr/bin/env bash
# verify_vectorization.sh — evidence that SIMD instructions are used (make report).
#
# For each build variant it:
#   1. recompiles kernels.c with that variant's flags, capturing the compiler's
#      vectorization report (GCC -fopt-info-vec; Clang -Rpass=loop-vectorize);
#   2. disassembles the kernel object (objdump -d) and, per kernel function,
#      counts total instructions, SIMD (packed) instructions and the widest
#      vector register touched (xmm/ymm/zmm);
#   3. saves the full report and disassembly under data/raw/vectorization/<ts>/
#      and writes data/processed/vectorization.csv for the report table.
#
# Quote short excerpts in the report (sec. Vectorization Verification); do not
# paste full dumps.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CC="${CC:-cc}"
CFLAGS="-std=gnu11 -g -Iinclude -I../../common/code/include"
declare -A VFLAGS=(
  [scalar]="-O3 -fno-tree-vectorize -fno-tree-slp-vectorize"
  [autovec]="-O3"
  [native]="-O3 -march=native"
)
VARIANTS=(scalar autovec native)
FUNCS=(saxpy_f32 dot_f32 mul_f32 stencil_f32 saxpy_f64 dot_f64 mul_f64 stencil_f64 mul_i32 saxpy_f32_stride saxpy_f32_gather saxpy_f32_gather_avx2)

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/data/raw/vectorization/$TS"
mkdir -p "$OUT"
CSV="$ROOT/data/processed/vectorization.csv"
mkdir -p "$ROOT/data/processed"
echo "variant,function,insns,simd_insns,widest_register" > "$CSV"

is_gcc=0
"$CC" --version 2>/dev/null | grep -qi 'gcc\|Free Software Foundation' && is_gcc=1

for v in "${VARIANTS[@]}"; do
  obj="$OUT/kernels_$v.o"
  rep="$OUT/report_$v.txt"
  dis="$OUT/disasm_$v.txt"

  # 1. compile + vectorization report
  if [ "$is_gcc" -eq 1 ]; then
    $CC $CFLAGS ${VFLAGS[$v]} -fopt-info-vec-optimized -fopt-info-vec-missed \
        -c src/kernels.c -o "$obj" 2> "$rep" || true
  else
    $CC $CFLAGS ${VFLAGS[$v]} -Rpass=loop-vectorize -Rpass-missed=loop-vectorize \
        -Rpass-analysis=loop-vectorize -c src/kernels.c -o "$obj" 2> "$rep" || true
  fi

  # 2. disassemble
  objdump -d --no-show-raw-insn "$obj" > "$dis" 2>/dev/null

  # 3. per-function instruction / SIMD counts + widest register
  awk -v variant="$v" -v csv="$CSV" -v keep="${FUNCS[*]}" -v OFS="," '
    BEGIN { split(keep, a, " "); for (i in a) want[a[i]] = 1 }
    function flush() {
      if (fn != "" && (fn in want)) {
        w = (zmm ? "zmm(512)" : (ymm ? "ymm(256)" : (xmm ? "xmm(128)" : "scalar")));
        print variant, fn, insns, simd, w >> csv
      }
    }
    BEGIN { fn = "" }
    /^[0-9a-f]+ <.*>:/ {
      flush();
      name = $0; sub(/^[0-9a-f]+ </, "", name); sub(/>:.*/, "", name);
      fn = name; insns = 0; simd = 0; xmm = 0; ymm = 0; zmm = 0; next
    }
    /^[ \t]+[0-9a-f]+:\t/ {
      if (fn == "") next;
      line = $0; sub(/^[^\t]*\t/, "", line);           # strip "  addr:\t"
      mnem = line; sub(/[ \t].*/, "", mnem);           # first token
      insns++;
      vec = 0;
      # packed float (…ps/…pd) but not scalar (…ss/…sd)
      if (mnem ~ /(ps|pd)$/ && mnem !~ /(ss|sd)$/) vec = 1;
      # AVX packed integer / any vp* ; SSE packed integer p{add,sub,mul,and,or,xor,cmp,min,max,unpck,shuf,mov}
      else if (mnem ~ /^vp/) vec = 1;
      else if (mnem ~ /^p(add|sub|mull|muld|mulh|and|andn|or|xor|cmp|min|max|unpck|shuf|mov|slld|srld)/) vec = 1;
      # AVX FMA (vfmadd… already ends ps/pd, caught above) and broadcasts
      else if (mnem ~ /^v(broadcast|perm|insert|extract|gather|blend|movdqa|movdqu|movap|movup|zeroupper)/) vec = 1;
      if (vec) simd++;
      if (line ~ /%zmm/) zmm = 1;
      else if (line ~ /%ymm/) ymm = 1;
      else if (vec && line ~ /%xmm/) xmm = 1;
      next
    }
    END { flush() }
  ' "$dis"
done

echo
echo "=== SIMD instruction summary ($CSV) ==="
column -s, -t "$CSV" 2>/dev/null || cat "$CSV"
echo
echo "Full reports and disassembly: $OUT"
echo "Vectorization reports (one line per variant, kernel loops):"
for v in "${VARIANTS[@]}"; do
  n=$(grep -c 'loop vectorized\|vectorized loop\|remark:.*vectorized' "$OUT/report_$v.txt" 2>/dev/null); n=${n:-0}
  echo "  $v: $n vectorized-loop messages (see report_$v.txt)"
done
