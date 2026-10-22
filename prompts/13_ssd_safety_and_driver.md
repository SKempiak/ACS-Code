# Prompt 15 — Safety guard and run driver (don't let me destroy a disk)

This project has a big "Data-loss Warning": never benchmark a partition with valuable data.
I want the scripts to make it *impossible* for me to point this at a real device by accident.

In `ACS-Code/SSD_Performance_Profiling/scripts/`, please write:

- `safety.sh <target>` — a gate that **hard-refuses** anything that isn't a plain disposable
  file inside a dedicated scratch directory: it must reject block/character devices, reject
  mountpoints, reject any path outside the scratch dir, require a regular file (or a
  not-yet-created one there), and check free space. It should print why it refused and exit
  non-zero. I'd like the scratch location to be overridable (e.g. an `ACS_SCRATCH` env var) so
  I can put the test file on whichever drive I actually want to profile — but the gate must be
  identical wherever it points.
- `run.sh <experiment>` — drives the required experiments (QD=1 zero-queue, block-size sweep,
  read/write mix, queue-depth sweep, tail latency, device-state, and the buffered-vs-direct
  pitfall) through `safety.sh` and `blkbench`, writing raw rows + an environment snapshot
  (including the device model and whether it's rotational) and summarizing into
  `data/processed/`.

Also record which disk the scratch file actually lands on — I want the report to name the
device under test, not guess.

---
**What this demonstrates:** treating data-safety as a hard precondition enforced in code (a
gate that cannot be talked into writing to a device), and capturing the identity of the device
actually under test so the results can't be mislabeled.
