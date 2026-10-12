/*
 * summarize.c — turn raw measurements into processed data (all projects).
 *
 * TODO:
 *   - Read raw result files (one row per repetition).
 *   - Group rows by configuration (the knobs that were varied).
 *   - Compute summary statistics per group (e.g. median and interquartile range, or mean
 *     and confidence interval) and the number of repetitions.
 *   - Write <project>/data/processed/<experiment>.csv. The ACS-Latex figures read these
 *     files directly with pgfplots, so keep the column names stable.
 */
