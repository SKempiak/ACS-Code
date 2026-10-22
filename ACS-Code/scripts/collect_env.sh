#!/usr/bin/env bash
# collect_env.sh — record the measurement environment alongside every run.
#
#   scripts/collect_env.sh            human-readable environment report (stdout)
#   scripts/collect_env.sh --tex      LaTeX \newcommand macros for
#                                     ../ACS-Latex/common/system_info.tex
#
# Linux-focused (lscpu, /proc, /sys, cpufreq). Fields that need root or a tool
# that is not installed are reported as "not available ..." rather than guessed,
# so the report can state honest limitations instead of inventing numbers.
set -uo pipefail

# ---- small helpers ----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
first() { awk 'NF{print; exit}'; }
na() { echo "not available${1:+ ($1)}"; }

cpu_model() { lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}'; }
arch()      { uname -m; }

isa_list() {
  local f="/proc/cpuinfo" out=() t
  for t in sse sse2 sse3 ssse3 sse4_1 sse4_2 avx avx2 fma f16c \
           avx512f avx512dq avx512bw avx512vl; do
    grep -qm1 "\b$t\b" "$f" 2>/dev/null && out+=("$t")
  done
  local widest="scalar/x87"
  if   grep -qm1 '\bavx512f\b' "$f" 2>/dev/null; then widest="512-bit (zmm)"
  elif grep -qm1 '\bavx\b'     "$f" 2>/dev/null; then widest="256-bit (ymm)"
  elif grep -qm1 '\bsse\b'     "$f" 2>/dev/null; then widest="128-bit (xmm)"
  fi
  echo "${out[*]} -- widest $widest"
}

cores() {
  local sockets cps tpc
  sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')
  cps=$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')
  tpc=$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2);print $2}')
  local logical; logical=$(nproc --all 2>/dev/null)
  local online; online=$(nproc 2>/dev/null)
  echo "${sockets:-?} socket(s), ${cps:-?} cores/socket, ${tpc:-?} threads/core (${online:-?} of ${logical:-?} logical CPUs online)"
}
smt() {
  local tpc; tpc=$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2);print $2}')
  if [ "${tpc:-1}" -gt 1 ] 2>/dev/null; then echo "on (${tpc} threads/core)"; else echo "off"; fi
}
caches() {
  lscpu 2>/dev/null | awk -F: '/^L1d cache|^L2 cache|^L3 cache/{
    k=$1; gsub(/ cache/,"",k); gsub(/^ +/,"",$2);
    printf "%s%s %s", (n++?"; ":""), k, $2 } END{print ""}'
}
numa() {
  local nodes; nodes=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2);print $2}')
  echo "${nodes:-1} node(s)"
}
governor() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || na "no cpufreq"; }
driver()   { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   2>/dev/null || na; }
turbo() {
  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 0 ] && echo "enabled" || echo "disabled"
  else na "no intel_pstate"; fi
}
epp() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || na; }
isolation() {
  local iso; iso=$(grep -o 'isolcpus=[^ ]*' /proc/cmdline 2>/dev/null)
  echo "${iso:-no isolcpus}"
}
memory() { awk '/MemTotal/{printf "%.0f GiB total\n",$2/1024/1024}' /proc/meminfo 2>/dev/null; }
dimm()   { if have dmidecode && dmidecode -t memory >/dev/null 2>&1; then
             dmidecode -t memory 2>/dev/null | awk -F: '/Speed:/{gsub(/^ +/,"",$2);print $2;exit}'
           elif [ -r "$(dirname "$0")/../env/dmidecode_memory.txt" ]; then
             # saved by the author with sudo (see env/dmidecode_memory.txt)
             echo '2 $\times$ 32 GiB DDR4-3200, one per channel (A, B), running at 2933 MT/s (dmidecode)'
           else na "needs root/dmidecode"; fi; }
pagesize()  { echo "$(getconf PAGE_SIZE 2>/dev/null) bytes"; }
hugepages() { sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || na; }
os()     { . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}"; }
kernel() { uname -r; }
ccver()    { cc --version 2>/dev/null | first; }
gccver()   { have gcc   && gcc --version   2>/dev/null | first || na "gcc not installed"; }
clangver() { have clang && clang --version 2>/dev/null | first || na "clang not installed"; }
perfver()  { have perf  && perf --version  2>/dev/null | first || na "not installed"; }
paranoid() { cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || na; }
fiover()   { have fio   && fio --version    2>/dev/null | first || na "not installed"; }
mlcver()   { have mlc   && echo "present"                       || na "not installed"; }
gpu() {
  if have nvidia-smi; then nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | first
  elif have lspci;    then lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/^[^ ]* //' || na
  else na; fi
}
cudaver() { have nvcc && nvcc --version 2>/dev/null | awk '/release/{print $NF;exit}' || na "no CUDA"; }
collected() { date '+%Y-%m-%d %H:%M %Z'; }

# ---- gather -----------------------------------------------------------------
V_CPU="$(cpu_model)";          V_ARCH="$(arch)";         V_ISA="$(isa_list)"
V_CORES="$(cores)";            V_SMT="$(smt)";           V_CACHES="$(caches)"
V_NUMA="$(numa)";              V_GOV="$(governor)";      V_DRV="$(driver)"
V_TURBO="$(turbo)";            V_EPP="$(epp)";           V_ISO="$(isolation)"
V_MEM="$(memory)";             V_DIMM="$(dimm)";         V_PAGE="$(pagesize)"
V_THP="$(hugepages)";          V_OS="$(os)";             V_KERNEL="$(kernel)"
V_CC="$(ccver)";               V_GCC="$(gccver)";        V_CLANG="$(clangver)"
V_PERF="$(perfver)";           V_PARANOID="$(paranoid)"; V_FIO="$(fiover)"
V_MLC="$(mlcver)";             V_GPU="$(gpu)";           V_CUDA="$(cudaver)"
V_COLLECTED="$(collected)"

# ---- output -----------------------------------------------------------------
if [ "${1:-}" = "--tex" ]; then
  texesc() { sed -e 's/\\/\\textbackslash{}/g' -e 's/\([#$%&_{}]\)/\\\1/g'; }
  m() { printf '\\newcommand{\\%s}{%s}\n' "$1" "$(printf '%s' "$2" | texesc)"; }
  cat <<'HDR'
%% Measurement environment macros, used by common/environment_table.tex.
%% GENERATED by ACS-Code/scripts/collect_env.sh --tex on the test machine.
%% Regenerate with:
%%   scripts/collect_env.sh --tex > ../ACS-Latex/common/system_info.tex
HDR
  m sysCPU "$V_CPU";            m sysArch "$V_ARCH";        m sysISA "$V_ISA"
  m sysCores "$V_CORES";        m sysSMT "$V_SMT";          m sysCaches "$V_CACHES"
  m sysNUMA "$V_NUMA";          m sysGovernor "$V_GOV";     m sysDriver "$V_DRV"
  m sysTurbo "$V_TURBO";        m sysEPP "$V_EPP";          m sysIsolation "$V_ISO"
  m sysMemory "$V_MEM";         m sysDIMM "$V_DIMM";        m sysPageSize "$V_PAGE"
  m sysHugePages "$V_THP";      m sysOS "$V_OS";            m sysKernel "$V_KERNEL"
  m sysCC "$V_CC";              m sysGCC "$V_GCC";          m sysClang "$V_CLANG"
  m sysPerf "$V_PERF";          m sysPerfParanoid "$V_PARANOID"
  m sysFio "$V_FIO";            m sysMLC "$V_MLC"
  m sysGPU "$V_GPU";            m sysCUDA "$V_CUDA";        m sysCollected "$V_COLLECTED"
  exit 0
fi

cat <<EOF
# Measurement environment  ($V_COLLECTED)
CPU                 : $V_CPU ($V_ARCH)
SIMD ISA            : $V_ISA
Topology            : $V_CORES
SMT                 : $V_SMT
Caches              : $V_CACHES
NUMA                : $V_NUMA
Memory              : $V_MEM; DIMM speed: $V_DIMM
Pages               : base $V_PAGE; THP: $V_THP
OS / kernel         : $V_OS; $V_KERNEL
Frequency policy    : governor $V_GOV; driver $V_DRV; turbo $V_TURBO; EPP $V_EPP
Pinning / isolation : $V_ISO
Compilers           : cc=$V_CC; $V_GCC; $V_CLANG
Tools               : perf=$V_PERF (perf_event_paranoid=$V_PARANOID); fio=$V_FIO; MLC=$V_MLC
GPU (optional)      : $V_GPU; CUDA $V_CUDA
EOF
