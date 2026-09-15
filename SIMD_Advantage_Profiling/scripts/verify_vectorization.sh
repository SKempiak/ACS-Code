#!/usr/bin/env bash
# verify_vectorization.sh — evidence that SIMD instructions are used (make report).
#
# TODO:
#   - Collect the compiler's vectorization report for each variant.
#   - Disassemble the kernel functions; identify vector instructions and register width.
#   - Save the full output under data/raw/ and pick short excerpts for the report
#     (quote evidence, not full dumps).
