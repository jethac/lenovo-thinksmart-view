#!/usr/bin/env python3
"""MeloTTS (PyTorch, CPU) renders for the bake-off: the lines of one
language from cases/rt-lines.tsv into OUTDIR/<speaker>-<line>.wav, with
the lexicon's alias for ai&.

    rt-render-melo.py LANG(JP|ZH|EN) LINES.tsv OUTDIR
"""
import sys, time
from melo.api import TTS

lang, lines, out = sys.argv[1:4]
code = {"JP": "ja", "ZH": "zh", "EN": "en"}[lang]
alias = {"ja": "エーアイアンド", "zh": "诶爱安德", "en": "A-I, and"}[code]
m = TTS(language=lang, device="cpu")
spk = m.hps.data.spk2id
name = list(spk.keys())[0] if lang != "EN" else "EN-US"
for l in open(lines, encoding="utf-8"):
    f = l.rstrip("\n").split("\t")
    if len(f) < 3 or f[1] != code:
        continue
    t0 = time.time()
    m.tts_to_file(f[2].replace("ai&", alias), spk[name], f"{out}/{name}-{f[0]}.wav", speed=1.0, quiet=True)
    print(f[0], round(time.time() - t0, 2), flush=True)
