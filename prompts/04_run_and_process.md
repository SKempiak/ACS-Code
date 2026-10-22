# Prompt 04 — Run scripts and data processing

Now wire up the experiments. Write `scripts/run.sh` with one entry point per required
experiment — `baseline`, `locality`, `alignment`, `stride`, `dtype`, `negative` — plus
`all`. Each should sweep the right knobs by calling the three variant binaries, write the
raw rows to `data/raw/<experiment>/<timestamp>/raw.csv` together with a snapshot of the
environment, and then produce `data/processed/<experiment>.csv`.

Also implement `tools/summarize.c`: read the raw per-repetition rows, group by
configuration, and write median / q25 / q75 per metric (plus a speedup-vs-scalar column
where it makes sense).

One thing to watch: the LaTeX report's pgfplots figures read these processed CSVs directly
and filter on specific column names (for example `only if={kernel}{saxpy}`,
`only if={variant}{autovec}`, `y=elems_per_s_median`, and `iqr of=elems_per_s`). So the
column names `summarize` writes have to match exactly what the figures expect, or the
plots come out empty. Please check the `.tex` files for the exact names before you finalize
the columns.

---
**What this demonstrates:** building a reproducible raw → processed → figure pipeline, and
the discipline of keeping the data contract (column names) in sync between the processing
code and the plotting code.
