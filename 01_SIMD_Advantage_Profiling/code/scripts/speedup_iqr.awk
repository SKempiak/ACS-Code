#!/usr/bin/awk -f
# speedup_iqr.awk — add speedup error-bar bounds to a summarized CSV.
#
#   awk -f scripts/speedup_iqr.awk data/processed/baseline.csv data/processed/baseline.csv > out.csv
#   (the file is given twice: pass 1 indexes the scalar rows, pass 2 rewrites)
#
# tools/summarize writes speedup_vs_scalar = median(variant) / median(scalar)
# but no spread for it. This appends
#   speedup_q25 = elems_per_s_q25(variant) / elems_per_s_q75(scalar)
#   speedup_q75 = elems_per_s_q75(variant) / elems_per_s_q25(scalar)
# i.e. the speedup range implied by the two interquartile ranges (a
# conservative bound: worst-case and best-case pairing of the quartiles).
# Group columns are all columns before the first *_median column; the scalar
# sibling of a row is the row with identical group values except variant.
# Rows/files without the needed columns pass through with NA bounds.
BEGIN { FS = OFS = "," }

FNR == 1 {
    ng = 0; vcol = 0; q25 = 0; q75 = 0; already = 0
    for (i = 1; i <= NF; i++) {
        if ($i ~ /_median$/ && !ng) ng = i - 1
        if ($i == "variant") vcol = i
        if ($i == "elems_per_s_q25") q25 = i
        if ($i == "elems_per_s_q75") q75 = i
        if ($i == "speedup_q25") already = 1
    }
    if (NR != FNR) {
        if (already) { print; next }
        print $0, "speedup_q25", "speedup_q75"
    }
    next
}

function key(   k, i) {
    k = ""
    for (i = 1; i <= ng; i++) if (i != vcol) k = k $i "|"
    return k
}

NR == FNR {                       # pass 1: scalar quartiles by sibling key
    if (vcol && $vcol == "scalar") { s25[key()] = $q25; s75[key()] = $q75 }
    next
}

{                                 # pass 2: emit with bounds
    if (already) { print; next }
    k = key(); lo = "NA"; hi = "NA"
    if (vcol && q25 && q75 && (k in s25) && s75[k] + 0 > 0 && s25[k] + 0 > 0) {
        lo = sprintf("%.6f", $q25 / s75[k])
        hi = sprintf("%.6f", $q75 / s25[k])
    }
    print $0, lo, hi
}
