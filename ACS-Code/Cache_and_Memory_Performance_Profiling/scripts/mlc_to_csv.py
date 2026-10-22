#!/usr/bin/env python3
"""mlc_to_csv.py — parse Intel MLC text output (run by `run.sh mlc`) into CSV (stdlib only).

    python3 scripts/mlc_to_csv.py <raw mlc dir> <processed dir>

Inputs (in the raw dir, written by run.sh):
  idle_<pages>_<KiB>KiB_rep<r>.txt   mlc --idle_latency -b<KiB> [-L] ...
  loaded_latency.txt                 mlc --loaded_latency ...
  peak_injection_bandwidth.txt       mlc --peak_injection_bandwidth ...
  max_bandwidth.txt                  mlc --max_bandwidth ...
Outputs:
  mlc_idle.csv     pages,buffer_kib,rep,clocks,ns
  mlc_loaded.csv   delay,ns,mb_s,gib_s           (MLC MB/s = 1e6 B/s, converted to GiB/s)
  mlc_bw.csv       mode,traffic,mb_s,gib_s
"""
import csv
import glob
import os
import re
import sys

GIB = 1024.0 ** 3


def mb_to_gib(mb):
    return mb * 1e6 / GIB


def main():
    raw, proc = sys.argv[1], sys.argv[2]
    idle = []
    for path in sorted(glob.glob(os.path.join(raw, "idle_*_rep*.txt"))):
        m = re.search(r"idle_(\w+?)_(\d+)KiB_rep(\d+)\.txt$", path)
        if not m:
            continue
        txt = open(path, errors="replace").read()
        t = re.search(r"Each iteration took\s+([\d.]+)\s+\S*\s*\S*\s*clocks\s*\(\s*([\d.]+)\s*ns\)", txt)
        if t:
            idle.append([m.group(1), int(m.group(2)), int(m.group(3)), float(t.group(1)), float(t.group(2))])
    if idle:
        with open(os.path.join(proc, "mlc_idle.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["pages", "buffer_kib", "rep", "clocks", "ns"])
            w.writerows(sorted(idle, key=lambda r: (r[0], r[1], r[2])))

    p = os.path.join(raw, "loaded_latency.txt")
    if os.path.exists(p):
        rows = []
        for line in open(p, errors="replace"):
            m = re.match(r"\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s*$", line)
            if m:
                d, ns, mb = int(m.group(1)), float(m.group(2)), float(m.group(3))
                rows.append([d, ns, mb, mb_to_gib(mb)])
        if rows:
            with open(os.path.join(proc, "mlc_loaded.csv"), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["delay", "ns", "mb_s", "gib_s"])
                w.writerows(rows)

    bw = []
    for mode in ("peak_injection_bandwidth", "max_bandwidth"):
        p = os.path.join(raw, mode + ".txt")
        if not os.path.exists(p):
            continue
        for line in open(p, errors="replace"):
            m = re.match(r"\s*([A-Za-z0-9:\- ]+?)\s*:\s*([\d.]+)\s*$", line)
            if m and any(k in m.group(1) for k in ("Read", "read", "Write", "triad")):
                label = re.sub(r"\s+", " ", m.group(1)).strip().replace(",", "")
                mb = float(m.group(2))
                bw.append([mode, label, mb, mb_to_gib(mb)])
    if bw:
        with open(os.path.join(proc, "mlc_bw.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["mode", "traffic", "mb_s", "gib_s"])
            w.writerows(bw)
    print(f"mlc_to_csv: idle={len(idle)} loaded={'yes' if os.path.exists(os.path.join(proc, 'mlc_loaded.csv')) else 'no'} "
          f"bw={len(bw)}", file=sys.stderr)


if __name__ == "__main__":
    main()
