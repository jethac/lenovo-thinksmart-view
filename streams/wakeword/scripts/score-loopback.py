"""Match the wakes in a straylight-listen log against the loopback file's clips.

    score-loopback.py LOG MARKS.json

The capture clock starts before playback; the offset is the one that puts
the most wakes within 0.5 s after a clip's end. A clip counts as detected if
a wake falls between its end - 0.1 s and end + 0.6 s.
"""
import json
import re
import sys

wakes = [float(m) for m in re.findall(r"wake at ([0-9.]+) s", open(sys.argv[1]).read())]
marks = json.load(open(sys.argv[2]))


def match(off):
    hit = []
    for m in marks:
        hit.append(any(m["end"] - 0.1 <= w - off <= m["end"] + 0.6 for w in wakes))
    return hit


best = max((sum(match(o / 100)), o / 100) for o in range(0, 1000))
off = best[1]
hit = match(off)
groups = {}
for m, h in zip(marks, hit):
    f = m["file"].split("/")[-1]
    key = m["kind"] + (" magpie-" + f.split("-")[2] if f.startswith("s4-") else " piper")
    groups.setdefault(key, []).append(h)
print(f"offset {off:.2f} s, {len(wakes)} wakes")
for k, v in groups.items():
    print(f"  {k}: {sum(v)}/{len(v)} {'detected' if k.startswith('pos') else 'false wakes'}")
unmatched = [w for w in wakes if not any(m['end'] - 0.1 <= w - off <= m['end'] + 0.6 for m in marks)]
print("  wakes not at a clip end:", unmatched)
