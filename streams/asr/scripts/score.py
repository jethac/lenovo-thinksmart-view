#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Score hypotheses against refs.tsv.

    score.py REFS_TSV HYPS_TSV LANG

REFS_TSV: id<TAB>wav<TAB>reference. HYPS_TSV: id<TAB>hypothesis (ids missing
from it count as empty output). LANG en -> WER with Whisper's English
normalizer; ja -> CER with Whisper's basic normalizer and spaces removed,
the same routing as transcribe.cpp's scripts/wer/score.py.
"""
import sys

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer


def main():
    refs_path, hyps_path, lang = sys.argv[1:4]
    refs = {}
    for line in open(refs_path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        refs[f[0]] = f[2]
    hyps = {}
    for line in open(hyps_path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t", 1)
        hyps[f[0]] = f[1] if len(f) > 1 else ""
    if lang == "en":
        norm = EnglishTextNormalizer()
    else:
        basic = BasicTextNormalizer()
        norm = lambda s: basic(s).replace(" ", "")
    ids = [i for i in refs if norm(refs[i])]
    r = [norm(refs[i]) for i in ids]
    h = [norm(hyps.get(i, "")) for i in ids]
    if lang == "en":
        o = jiwer.process_words(r, h)
        rate = o.wer
    else:
        o = jiwer.process_characters(r, h)
        rate = o.cer
    print(f"{'WER' if lang == 'en' else 'CER'} {rate * 100:.2f}% n={len(ids)} "
          f"missing={sum(1 for i in ids if i not in hyps)}")


if __name__ == "__main__":
    main()
