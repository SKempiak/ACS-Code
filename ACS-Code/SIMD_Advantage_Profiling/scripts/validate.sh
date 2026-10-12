#!/usr/bin/env bash
# validate.sh — correctness validation for every build variant (make test).
#
# TODO:
#   - Compare each kernel's output with src/reference.c for every variant and data type.
#   - Cover sizes with and without vector-width remainders, offset (misaligned) arrays,
#     strides and gather patterns.
#   - Add known-answer sanity checks that don't depend on the reference.
#   - Exit non-zero on any mismatch.
