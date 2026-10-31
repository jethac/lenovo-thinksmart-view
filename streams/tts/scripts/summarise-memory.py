"""Summarise device-memory.sh output: per run, wall time of each process, peak
RSS (anonymous / file-backed), lowest MemAvailable, major page faults.

    summarise-memory.py OUTDIR
"""
import os, sys
d = sys.argv[1]
def num(x):
    try: return int(x)
    except ValueError: return None
print("| Run | ASR time | TTS time | ASR peak RSS (anon + file) | TTS peak RSS (anon + file) | Lowest MemAvailable | Major faults ASR / TTS |")
print("|---|---|---|---|---|---|---|")
for run in ("asr", "tts", "both"):
    p = os.path.join(d, f"mem-{run}.tsv")
    if not os.path.exists(p): continue
    rows = [l.split() for l in open(p)][1:]
    col = lambda i: [num(r[i]) for r in rows if len(r) > i and num(r[i]) is not None]
    def peak(a, f):
        s = [x + y for x, y in zip(col(a), col(f))] if col(a) else []
        if not s: return "-"
        i = s.index(max(s)); return f"{max(s)/1024:.0f} MiB ({col(a)[i]/1024:.0f} + {col(f)[i]/1024:.0f})"
    t = lambda w: (open(os.path.join(d, f"{w}-{run}.ms")).read().strip() if os.path.exists(os.path.join(d, f"{w}-{run}.ms")) else None)
    fmt = lambda v: f"{int(v)/1000:.0f} s" if v else "-"
    mf = lambda i: str(max(col(i))) if col(i) else "-"
    print(f"| {run} | {fmt(t('asr'))} | {fmt(t('tts'))} | {peak(3, 4)} | {peak(7, 8)} | {min(col(1))/1024:.0f} MiB | {mf(6)} / {mf(10)} |")
