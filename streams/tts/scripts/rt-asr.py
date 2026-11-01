#!/usr/bin/env python3
"""ASR round trip and pitch of the bake-off samples: for every
<voice>-<line>.wav under the given directories, Qwen3-ASR (transcribe.cpp
CLI, as kokoro-asr-check.py) against the line's text, CER over normalised
characters (lower case, no punctuation or spaces), and the median voiced F0
(librosa pYIN). One TSV row per file, then the mean CER per voice and
language.

    rt-asr.py LINES.tsv TRANSCRIBE_CLI ASR_MODEL DIR...
"""
import collections, os, subprocess, sys, tempfile, unicodedata
import librosa, numpy as np, soundfile as sf

lines_tsv, cli, model = sys.argv[1:4]
dirs = sys.argv[4:]
ALIAS = {"ja": "エーアイアンド", "zh": "诶爱安德", "en": "A-I and"}
text = {}
for l in open(lines_tsv, encoding="utf-8"):
    f = l.rstrip("\n").split("\t")
    if len(f) >= 3:
        text[f[0]] = (f[1], f[2].replace("ai&", ALIAS[f[1]]))


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
print("file\tlang\taudio_s\tf0_hz\tcer\ttranscript")
for d in dirs:
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".wav"):
            continue
        key = next((k for k in text if fn[:-4].endswith("-" + k)), None)
        if not key:
            continue
        voice = fn[: -len(key) - 5]
        lang, ref = text[key]
        y, sr = librosa.load(os.path.join(d, fn), sr=16000)
        f0, vf, _ = librosa.pyin(y, fmin=70, fmax=500, sr=16000)
        f0m = float(np.nanmedian(f0[vf])) if vf.any() else 0.0
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=os.environ.get("TMPDIR")) as tf:
            sf.write(tf.name, y, 16000, subtype="PCM_16")
            subprocess.run([cli, "-q", "-m", model, "-l", lang, "--threads", "8", "-o", tf.name + ".txt", tf.name], capture_output=True)
            h = open(tf.name + ".txt", encoding="utf-8").read().strip() if os.path.exists(tf.name + ".txt") else ""
            if os.path.exists(tf.name + ".txt"):
                os.remove(tf.name + ".txt")
        c = cer(ref, h)
        by[(os.path.basename(d.rstrip("/")), voice, lang)].append(c)
        print(f"{os.path.basename(d.rstrip('/'))}/{fn}\t{lang}\t{len(y) / 16000:.2f}\t{f0m:.0f}\t{c:.3f}\t{h}", flush=True)
for (m, v, lang), cs in sorted(by.items()):
    print(f"# {m}/{v} {lang}: mean CER {100 * sum(cs) / len(cs):.1f} % over {len(cs)}")
