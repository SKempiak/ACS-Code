# Prompt 14 — Queue-depth knee, Little's Law, and tail latency

I have the queue-depth sweep (`data/processed/queue_depth.csv`: IOPS and latency percentiles
at iodepth 1…128, 4 KiB random reads) and a tail-latency run at a mid and a near-knee queue
depth. Help me write the two analysis sections.

For the queue-depth section (part of a 40-point item): plot the single throughput-vs-latency
curve, identify the saturation knee, and discuss diminishing returns past it. Then do the
Little's Law check: the outstanding I/O count should be $L = \lambda W$ (IOPS × mean latency),
and it should track the configured iodepth while the queue stays full — build the table and
point out the queue depth where measured $\lambda W$ starts to fall below the configured depth,
and say what that reveals (host-side submission limits, engine not keeping the queue full).

For the tail-latency section: compare p50/p95/p99/p99.9 at the mid vs. near-knee depth and
explain why the tail amplifies with queueing, and why tails matter more than the mean for this
kind of workload.

Keep me honest: if the knee or the Little's-Law departure looks like my benchmark's limit
rather than the device's, say so.

---
**What this demonstrates:** connecting a measured storage knee to queueing theory (Little's
Law) and reasoning about tail latency, while distinguishing a device limit from a
benchmark-harness limit.
