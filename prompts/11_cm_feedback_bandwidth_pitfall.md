# Prompt 12 — Feedback: is my DRAM-bandwidth benchmark actually measuring DRAM?

Before I write up the results I want you to poke holes in my method. Here's a bandwidth
microbenchmark I wrote earlier:

```c
float buf[4096];                 // 16 KiB
for (int rep = 0; rep < 1000; rep++)
    for (int i = 0; i < 4096; i++) sink += buf[i];
// report: bytes_touched / elapsed  -> ~56 GiB/s, call it "DRAM bandwidth"
```

It reports about 56 GiB/s and I was about to put that in the report as the machine's memory
bandwidth. But my zero-queue latency section says DRAM is ~84 ns away, and the intensity
sweep tops out around 30 GiB/s even with ten threads. Something doesn't add up. Can you tell
me what's wrong with this benchmark, whether 56 GiB/s is believable as "DRAM bandwidth," how I
could detect the problem automatically, and what the right experiment is? Also sanity-check my
huge-pages experiment: I assumed transparent huge pages were in effect because the governor
says `always` — is that safe to assume?

---
**What this demonstrates:** catching the most common memory-benchmark pitfall — measuring
cache reuse instead of DRAM because the working set fits in cache — and refusing to trust an
assumption (huge pages "on") without verifying it at runtime.
