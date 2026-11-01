#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Score screen.py outputs: one row per output directory.

    screen-score.py OUT_DIR...

Columns: command sets en (WER), ja, zh (CER); phrase set groups en (WER), ja,
zh, mx (CER), lx-en (WER), lx-ja, lx-zh (CER); corpus-level, with the same
normalisers as ../asr/scripts/score.py.
"""
import os
import re
import sys

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "..", "asr", "work", "testset")
EN, BASIC = EnglishTextNormalizer(), BasicTextNormalizer()


def norm(t, lang):
    return EN(t) if lang == "en" else BASIC(t).replace(" ", "")


def rate(pairs, lang):
    r = [norm(a, lang) for a, _ in pairs]
    h = [norm(b, lang) for _, b in pairs]
    keep = [i for i, x in enumerate(r) if x]
    r, h = [r[i] for i in keep], [h[i] for i in keep]
    if not r:
        return float("nan")
    return (jiwer.process_words(r, h).wer if lang == "en" else jiwer.process_characters(r, h).cer) * 100


def load(path):
    d = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            f = line.rstrip("\n").split("\t", 1)
            d[f[0]] = f[1] if len(f) > 1 else ""
    return d


def refs(s):
    return [l.rstrip("\n").split("\t") for l in open(os.path.join(TS, s, "refs.tsv"), encoding="utf-8")]


COLS = ["en", "ja", "zh", "p-en", "p-ja", "p-zh", "p-mx", "lx-en", "lx-ja", "lx-zh"]


def main():
    print("| model | " + " | ".join(COLS) + " |")
    print("| --- |" + " --- |" * len(COLS))
    for d in sys.argv[1:]:
        row = {}
        for s, lang in (("cmd-en", "en"), ("cmd-ja", "ja"), ("cmd-zh", "zh")):
            h = load(os.path.join(d, f"{s}.tsv"))
            row[s[4:]] = rate([(r[2], h.get(r[0], "")) for r in refs(s)], lang)
        h = load(os.path.join(d, "phrase.tsv"))
        groups = {}
        for cid, _, ref in refs("phrase"):
            g = re.sub(r"-\d+$", "", cid)
            groups.setdefault(g, []).append((ref, h.get(cid, "")))
        for g, pairs in groups.items():
            key = g if g.startswith("lx-") else "p-" + g
            row[key] = rate(pairs, "en" if g in ("en", "lx-en") else "cjk")
        print(f"| {os.path.basename(d.rstrip('/'))} | " + " | ".join(f"{row.get(c, float('nan')):.2f}" for c in COLS) + " |")


if __name__ == "__main__":
    main()
