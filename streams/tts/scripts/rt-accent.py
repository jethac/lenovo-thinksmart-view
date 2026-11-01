#!/usr/bin/env python3
"""Pitch-accent check on minimal pairs (cases/ja-accent.tsv): each line
starts with a two-mora word whose Tokyo accent either falls after the first
mora (HL: 雨, 神, 鮭, 二本) or rises into the second (LH: 飴, 紙, 酒, 日本);
all its morae are voiced. The time of the F0 peak in the first 0.45 s
after voicing starts (pYIN) separates them: an HL word peaks in its first
mora, an LH word later. Each pair is compared within one voice, so the
phrase-initial rise and the speaking rate cancel out. A rough, objective
proxy for listening: it says whether the model tells the pair apart in
the right direction, not how natural it sounds.

    rt-accent.py DIR...      (files <voice>-acc-<word>-<HL|LH>.wav)
"""
import collections, os, sys
import librosa, numpy as np

peaks = {}
print("file\texpected\tpeak_ms")
for d in sys.argv[1:]:
    for fn in sorted(os.listdir(d)):
        if "-acc-" not in fn or not fn.endswith(".wav"):
            continue
        voice, rest = fn[:-4].split("-acc-")
        word, exp = rest.rsplit("-", 1)
        y, sr = librosa.load(os.path.join(d, fn), sr=16000)
        f0, vf, _ = librosa.pyin(y, fmin=70, fmax=500, sr=sr, frame_length=1024, hop_length=160)
        t = np.arange(len(f0)) * 160 / sr
        on = t[np.argmax(vf)] if vf.any() else 0
        sel = vf & (t >= on) & (t < on + 0.45)
        pk = float(t[sel][np.nanargmax(f0[sel])] - on) if sel.any() else float("nan")
        peaks[(os.path.basename(d.rstrip("/")), voice, word, exp)] = pk
        print(f"{os.path.basename(d.rstrip('/'))}/{fn}\t{exp}\t{pk * 1000:.0f}")
res = collections.defaultdict(list)
for (m, v, w, e), pk in peaks.items():
    if e == "HL" and (m, v, w, "LH") in peaks:
        res[(m, v)].append((w, peaks[(m, v, w, "LH")] - pk))
for (m, v), r in sorted(res.items()):
    ok = sum(1 for _, d in r if d > 0.03)
    print(f"# {m}/{v}: {ok}/{len(r)} pairs with the HL word peaking earlier than the LH word (" + ", ".join(f"{w} {d * 1000:+.0f} ms" for w, d in sorted(r)) + ")")
