# Prompt 15 — Feedback: why are my SSD numbers impossibly good?

Poke holes in this before I submit it. I ran a quick 4 KiB sequential read test on my
disposable file and got **~2 million IOPS and about 7.6 GiB/s at well under a microsecond of
latency**. That would be an incredible result and I was ready to report it as the drive's
small-block read performance.

But my QD=1 direct-I/O baseline for the same block size is only tens of thousands of IOPS at
tens of microseconds. The only difference between the two runs is that the fast one didn't use
`O_DIRECT`. What's actually going on? Is 2M IOPS a real device number? How would I prove it one
way or the other, and how should the benchmark be set up so the number describes the SSD
instead of something else? While you're at it: I set `iodepth=32` in one run but my async
engine might only have kept a couple of I/Os in flight — how do I check my *effective* queue
depth so I don't mislabel a QD=2 result as QD=32?

---
**What this demonstrates:** recognizing the classic storage-benchmark traps — buffered I/O
measuring the page cache (RAM) instead of the device, and a requested queue depth that the
harness never actually sustains — and knowing how to detect and avoid both.
