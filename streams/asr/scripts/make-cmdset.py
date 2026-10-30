#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Pick short clips (2-8 s) per language into work/testset/cmd-<lang>/ with refs.tsv
(id<TAB>wav<TAB>reference), the format score.py reads. Shortest first, N per language.

    make-cmdset.py N
"""
import csv, os, sys

import numpy as np
import soundfile as sf

N = int(sys.argv[1])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DL, OUT = os.path.join(ROOT, "downloads", "audio"), os.path.join(ROOT, "work", "testset")

def dur(p):
    i = sf.info(p)
    assert i.samplerate == 16000 and i.channels == 1, (p, i.samplerate, i.channels)
    return i.frames / 16000

def emit(lang, items):
    d = os.path.join(OUT, f"cmd-{lang}"); os.makedirs(d, exist_ok=True)
    picked = sorted((x for x in items if 2.0 <= x[2] <= 8.0), key=lambda x: x[2])[:N]
    with open(os.path.join(d, "refs.tsv"), "w", encoding="utf-8") as f, open(os.path.join(d, "list.txt"), "w") as l:
        for cid, src, s, ref in picked:
            dst = os.path.join(d, cid + ".wav")
            a, _ = sf.read(src, dtype="float32"); sf.write(dst, np.clip(a, -1, 1), 16000, subtype="PCM_16")
            f.write(f"{cid}\t{dst}\t{ref}\n"); l.write(dst + "\n")
    print(lang, len(picked), "clips,", f"{min(p[2] for p in picked):.1f}-{max(p[2] for p in picked):.1f} s")

# English: the LibriSpeech clips already prepared for the WER set
en = []
for line in open(os.path.join(OUT, "en-wer", "refs.tsv"), encoding="utf-8"):
    cid, wav, ref = line.rstrip("\n").split("\t", 2)
    wav = wav if os.path.isabs(wav) else os.path.join(ROOT, wav)
    en.append((cid, wav, dur(wav), ref))
emit("en", en)

# Japanese and Mandarin: FLEURS test splits (id, file, raw transcription, ...)
for lang, sub in (("ja", "fleurs-ja"), ("zh", "fleurs-zh")):
    base, seen, items = os.path.join(DL, sub), set(), []
    for row in csv.reader(open(os.path.join(base, "test.tsv"), encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE):
        f = os.path.join(base, "test", row[1])
        if row[1] in seen or not os.path.exists(f): continue
        seen.add(row[1]); items.append((f"{lang}-{os.path.splitext(row[1])[0]}", f, dur(f), row[2]))
    emit(lang, items)
