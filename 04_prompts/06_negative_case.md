# Prompt 06 — Design the negative / failure case

The project requires at least one case where the expected SIMD optimization does *not* help,
or where a naive benchmark would mislead. Help me design and run one, and make sure it's
convincing rather than hand-wavy.

I'm thinking of the memory-bound angle: a loop that genuinely vectorizes but shows almost no
speedup once the working set is larger than the last-level cache, because DRAM bandwidth
dominates. Use SAXPY for this since we already know it vectorizes. Add a `negative`
experiment that sweeps it from a cache-resident size out to a few hundred MB, and show the
speedup collapsing toward 1×.

Please make the argument airtight: confirm with the disassembly that the loop really is
vectorized (so it's not just a failure to use SIMD), and tie the DRAM throughput to a
bandwidth number so it's clear *why* the speedup vanished. If you notice any other kernel
that "looks vectorized but isn't actually fast," flag it — that would strengthen the
section.

---
**What this demonstrates:** the required negative case done rigorously — showing a
vectorized loop that still doesn't speed up, and explaining the cause (bandwidth) with
evidence instead of asserting it.
