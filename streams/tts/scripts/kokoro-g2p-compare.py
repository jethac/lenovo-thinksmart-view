#!/usr/bin/env python3
"""Compare straylight-listen's front end with Python misaki, line by line.

    kokoro-g2p-compare.py REF.tsv OURS.tsv [--diff]

REF: kokoro-reference.py phonemes output (id, lang, phonemes, ids);
OURS: straylight-listen --g2p output (id, lang, phonemes, ms).
Prints per language: lines identical, phoneme error rate (Levenshtein over
characters, spaces ignored), and with --diff each differing line.
"""
import sys, collections
def lev(a, b):
    p = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        c = [i]
        for j, y in enumerate(b, 1):
            c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (x != y)))
        p = c
    return p[-1]
ref = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()}
ours = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in open(sys.argv[2], encoding="utf-8") if l.strip()}
st = collections.defaultdict(lambda: [0, 0, 0, 0])
for k, r in ref.items():
    if k not in ours:
        continue
    lang, a, b = r[1], r[2].replace(" ", ""), ours[k][2].replace(" ", "")
    s = st[lang]
    s[0] += 1; s[1] += (r[2] == ours[k][2]); s[2] += lev(a, b); s[3] += len(a)
    if "--diff" in sys.argv and r[2] != ours[k][2]:
        print(f"{k}\n  misaki: {r[2]}\n  ours:   {ours[k][2]}")
for lang, (n, same, e, tot) in sorted(st.items()):
    print(f"{lang}: {same}/{n} identical, phoneme error rate {100*e/max(tot,1):.2f} % ({e} edits / {tot} phonemes, spaces ignored)")
