# Prompt 13 — Feedback: AI-use note and measurement-rigor review (Cache & Memory)

You wrote most of the code and the first drafts for this Cache & Memory project. The rubric
has an "AI-use transparency" item and a separate "experimental rigor" item, and my professor
says polished AI output without validated methodology isn't enough. Be straight with me.

Two things:

1. Review the measurement rigor honestly. Did we pin threads? Is the frequency fixed, and if
   not, how did we keep the cycle-per-access numbers meaningful? How many repetitions, and are
   there error bars? Which of the required experiments are weaker than the others because
   `perf` counters and Intel MLC aren't installed — and did we *say so* rather than paper over
   it? Flag anything a grader could reasonably attack.
2. Draft the honest AI-use note for the report and update `ACS-Code/AI_USE_LOG.md`. I want it
   concrete: which tools/models, what you generated, what I had to change, and at least one
   place where your suggestion was actually wrong or misleading and how it was caught — not a
   vague disclaimer.

---
**What this demonstrates:** using an AI agent as a critical reviewer of its own output —
turning the AI-use note and the rigor discussion into an honest account (counters missing,
frequency floating, assumptions verified) instead of a flattering summary.
