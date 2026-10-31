"""Objective measures of the listening samples: duration, pitch, speaking rate,
and an ASR round trip (Qwen3-ASR transcript, character error rate).

    analyse-samples.py LINES.tsv SAMPLEDIR TRANSCRIBE_CLI ASR_MODEL > table.tsv

Pitch is the median and 10-90 % range of voiced F0 (librosa pYIN). Rate is
characters of the normalised text per second of speech (leading and trailing
silence trimmed). CER compares normalised text: lower case, no punctuation or
spaces; Japanese/Mandarin per character.
"""
import os, re, subprocess, sys, unicodedata

import tempfile

import librosa
import soundfile as sf
import numpy as np

lines_tsv, sdir, cli, model = sys.argv[1:5]
lines = {}
for l in open(lines_tsv, encoding="utf-8"):
    if l.strip() and not l.startswith("#"):
        i, lang, text = l.rstrip("\n").split("|", 2)
        lines[i] = (lang, text)

def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if not unicodedata.category(c).startswith(("P", "Z", "S")))

def cer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)] / max(1, len(r))

print("file\tlang\taudio_s\tspeech_s\tf0_median_hz\tf0_p10_hz\tf0_p90_hz\tchars_per_s\tcer\ttranscript")
for fn in sorted(f for f in os.listdir(sdir) if f.endswith(".wav")):
    spk, lid = fn[:-4].split("-", 1)
    lang, text = lines[lid]
    y, sr = librosa.load(os.path.join(sdir, fn), sr=None)
    yt, _ = librosa.effects.trim(y, top_db=35)
    f0, vflag, _ = librosa.pyin(y, fmin=60, fmax=500, sr=sr, frame_length=1024)
    f0 = f0[vflag & ~np.isnan(f0)]
    with tempfile.NamedTemporaryFile(suffix=".wav") as tf:   # the ASR takes 16 kHz
        sf.write(tf.name, librosa.resample(y, orig_sr=sr, target_sr=16000), 16000, subtype="PCM_16")
        subprocess.run([cli, "-q", "-m", model, "-l", lang, "--threads", "6", "-o", tf.name + ".txt", tf.name],
                       capture_output=True, text=True)
        hyp = open(tf.name + ".txt", encoding="utf-8").read().strip().replace("\n", " ")
        os.remove(tf.name + ".txt")
    print(f"{fn}\t{lang}\t{len(y)/sr:.2f}\t{len(yt)/sr:.2f}\t{np.median(f0):.0f}\t{np.percentile(f0,10):.0f}\t"
          f"{np.percentile(f0,90):.0f}\t{len(norm(text))/(len(yt)/sr):.1f}\t{cer(text, hyp):.3f}\t{hyp}", flush=True)
