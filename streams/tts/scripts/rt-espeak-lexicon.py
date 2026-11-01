#!/usr/bin/env python3
"""Per-word espeak-ng (en-us) lexicon for sherpa-onnx's --vits-lexicon /
--matcha-lexicon, covering the English words of a lines TSV. Only for timing
Piper/Matcha models with the sherpa-onnx CLI on the tablet (sherpa-onnx 2.x
no longer phonemizes for them); laptop-only, espeak-ng is not shipped.

    rt-espeak-lexicon.py LINES.tsv TOKENS.txt > lexicon.txt
"""
import re, sys
import espeakng_loader as e
from phonemizer.backend.espeak.wrapper import EspeakWrapper

EspeakWrapper.set_library(e.get_library_path())
EspeakWrapper.set_data_path(e.get_data_path())
from phonemizer.backend import EspeakBackend

lines, tokens = sys.argv[1:3]
tok = {l.rsplit(" ", 1)[0] for l in open(tokens, encoding="utf-8") if l.strip()}
words = set()
for l in open(lines, encoding="utf-8"):
    f = l.rstrip("\n").split("\t")
    if len(f) >= 3 and f[1] == "en":
        words.update(w.lower() for w in re.findall(r"[A-Za-z][A-Za-z']*", f[2].replace("ai&", "A I and")))
b = EspeakBackend("en-us", with_stress=True)
ws = sorted(words)
for w, p in zip(ws, b.phonemize(ws)):
    ph = [c for c in p.strip() if c in tok and c != " "]
    print(w, " ".join(ph))
