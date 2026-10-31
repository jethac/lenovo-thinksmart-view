#!/usr/bin/env python3
"""Export the text front end's data for straylight-listen's Kokoro voice.

    kokoro-frontend-data.py OUTDIR

Writes (all UTF-8, small, read once at start):
  en-us.lex          misaki us_gold + us_silver (Apache-2.0), after misaki's
                     grow_dictionary: "word<TAB>g|s<TAB>phonemes" or, for
                     words with tagged variants, "TAG=ps;TAG=ps" (DEFAULT
                     first; an empty ps means None).
  g2p-en.bin         g2p_en's GRU grapheme-to-phoneme network (Apache-2.0,
                     Kyubyong Park), the fallback for unknown English words:
                     "G2PE" + count, then per tensor name, ndim, dims, f32.
  zh-phrases.tsv     pypinyin's PHRASES_DICT (MIT): phrase<TAB>tone3 tone3 ...
  zh-chars.tsv       pypinyin's PINYIN_DICT first reading per character, tone3
                     with neutral tone 5 (lazy_pinyin's choice).
  zh-syllables.tsv   tone3 syllable<TAB>misaki IPA (ZHG2P.py2ipa), for every
                     syllable either table produces.
Run with downloads/kokoro-venv.
"""
import json, os, struct, sys
import numpy as np

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

from misaki import en as men, data as mdata
import importlib.resources
def load(name):
    with importlib.resources.open_text(mdata, name) as r:
        return men.Lexicon.grow_dictionary(json.load(r))
gold, silver = load("us_gold.json"), load("us_silver.json")
with open(os.path.join(out, "en-us.lex"), "w", encoding="utf-8") as f:
    for src, d in (("g", gold), ("s", silver)):
        for w in sorted(d):
            v = d[w]
            if isinstance(v, str):
                f.write(f"{w}\t{src}\t{v}\n")
            else:
                items = [("DEFAULT", v["DEFAULT"])] + [(k, x) for k, x in v.items() if k != "DEFAULT"]
                f.write(f"{w}\t{src}\t" + ";".join(f"{k}={x or ''}" for k, x in items) + "\n")

import g2p_en
z = np.load(os.path.join(os.path.dirname(g2p_en.__file__), "checkpoint20.npz"))
with open(os.path.join(out, "g2p-en.bin"), "wb") as f:
    f.write(b"G2PE" + struct.pack("<I", len(z.files)))
    for k in sorted(z.files):
        a = np.ascontiguousarray(z[k], dtype=np.float32)
        kb = k.encode()
        f.write(struct.pack("<I", len(kb)) + kb + struct.pack("<I", a.ndim) + struct.pack(f"<{a.ndim}I", *a.shape))
        f.write(a.tobytes())

from pypinyin import Style, lazy_pinyin
from pypinyin.constants import PHRASES_DICT, PINYIN_DICT
from pypinyin.style import convert as style_convert
from misaki.zh import ZHG2P
def tone3(han, py):
    return style_convert(py, Style.TONE3, strict=True, neutral_tone_with_five=True)
syl = set()
with open(os.path.join(out, "zh-phrases.tsv"), "w", encoding="utf-8") as f:
    for ph in sorted(PHRASES_DICT):
        pys = [tone3(c, p[0]) for c, p in zip(ph, PHRASES_DICT[ph])]
        syl.update(pys)
        f.write(f"{ph}\t{' '.join(pys)}\n")
with open(os.path.join(out, "zh-chars.tsv"), "w", encoding="utf-8") as f:
    for cp in sorted(PINYIN_DICT):
        c = chr(cp)
        p = lazy_pinyin(c, style=Style.TONE3, neutral_tone_with_five=True)[0]
        syl.add(p)
        f.write(f"{c}\t{p}\n")
bad = 0
with open(os.path.join(out, "zh-syllables.tsv"), "w", encoding="utf-8") as f:
    for s in sorted(syl):
        try:
            f.write(f"{s}\t{ZHG2P.py2ipa(s).replace(chr(815), '')}\n")
        except Exception:
            bad += 1
print(f"{len(gold)} gold, {len(silver)} silver, {len(PHRASES_DICT)} phrases, {len(PINYIN_DICT)} chars, {len(syl)} syllables ({bad} without IPA)")
