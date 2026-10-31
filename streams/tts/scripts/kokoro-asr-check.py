#!/usr/bin/env python3
"""ASR round trip of rendered lines: CER per WAV and per language.

    kokoro-asr-check.py LINES.tsv DIR TRANSCRIBE_CLI ASR_MODEL

DIR has <id>.wav for the ids of LINES.tsv (id, lang, text). Qwen3-ASR via
transcribe.cpp's CLI, CER over characters (lower case, no punctuation or
spaces; English letters too), as in kokoro-voices.py.
"""
import os, subprocess, sys, tempfile, unicodedata, collections
import librosa, soundfile as sf
lines_tsv, d, cli, model = sys.argv[1:5]
def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if not unicodedata.category(c).startswith(("P", "Z", "S")))
def cer(r, h):
    r, h = norm(r), norm(h)
    p = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        c = [i]
        for j, hc in enumerate(h, 1):
            c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (rc != hc)))
        p = c
    return p[-1] / max(1, len(r))
by = collections.defaultdict(list)
for l in open(lines_tsv, encoding="utf-8"):
    if not l.strip() or l.startswith("#"):
        continue
    i, lang, text = l.rstrip("\n").split("\t", 2)
    f = os.path.join(d, i + ".wav")
    if not os.path.exists(f):
        continue
    y, sr = librosa.load(f, sr=16000)
    with tempfile.NamedTemporaryFile(suffix=".wav") as tf:
        sf.write(tf.name, y, 16000, subtype="PCM_16")
        subprocess.run([cli, "-q", "-m", model, "-l", lang, "--threads", "6", "-o", tf.name + ".txt", tf.name], capture_output=True)
        h = open(tf.name + ".txt", encoding="utf-8").read().strip() if os.path.exists(tf.name + ".txt") else ""
        if os.path.exists(tf.name + ".txt"):
            os.remove(tf.name + ".txt")
    c = cer(text, h)
    by[lang].append(c)
    print(f"{i}\t{c:.3f}\t{h}")
for lang, v in sorted(by.items()):
    print(f"# {lang}: mean CER {100*sum(v)/len(v):.2f} % over {len(v)}")
