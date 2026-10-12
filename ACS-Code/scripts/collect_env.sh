#!/usr/bin/env bash
# collect_env.sh — record the measurement environment alongside every run.
#
# TODO: capture at least
#   - CPU model, SIMD ISA extensions, core/thread topology, SMT state, cache sizes, NUMA
#   - memory size and configuration
#   - OS and kernel version
#   - compiler and tool versions (gcc/clang, perf, fio, Intel MLC)
#   - CPU frequency governor/driver and turbo state
#   - pinning / isolation settings and transparent huge page mode
#   - GPU and CUDA version (optional extension)
#
# Optionally also emit LaTeX macros for ../ACS-Latex/common/system_info.tex (the macro
# names are listed in that file) so the reports' environment table fills itself in.
