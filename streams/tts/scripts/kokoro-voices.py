#!/usr/bin/env python3
"""Objective measures of the Kokoro voice samples (work/kokoro-samples/).

    kokoro-voices.py LINES.tsv SAMPLEDIR REF_VOICE TRANSCRIBE_CLI ASR_MODEL OUT_PREFIX

Per WAV (<voice>-<line>.wav): length, speech length (35 dB trim), median and
10-90 % range of voiced F0 (librosa pYIN), characters of the normalised text
per second of speech, and the CER of a Qwen3-ASR round trip
(transcribe.cpp's CLI; lower case, no punctuation or spaces, per character
for every language, so English CER counts letters).

Per voice, against REF_VOICE (the English pick):
  - style-vector cosine similarity (voices/*.pt mean over the 510 rows):
    all 256 values, the first 128 (the decoder's half: timbre) and the last
    128 (the duration/F0 predictor's half: prosody);
  - spectral distance on the rendered audio: RMS difference of the
    long-term average spectrum (64 mel bands, dB, level-normalised) and the
    Euclidean distance of the mean MFCC 1-12, all of a voice's files pooled.
Blends are named like the render script names them (a*0.7+b*0.3 -> ax0.7_bx0.3);
their style vector is the same weighted mean the renderer used.

Writes OUT_PREFIX.files.tsv and OUT_PREFIX.voices.tsv.
"""
import os, subprocess, sys, tempfile, unicodedata
import numpy as np, librosa, soundfile as sf, torch

lines_tsv, sdir, ref, cli, model, outp = sys.argv[1:7]
HERE = os.path.dirname(os.path.abspath(__file__))
VDIR = os.path.join(HERE, "..", "downloads", "kokoro", "hexgrad", "voices")
lines = {}
for l in open(lines_tsv, encoding="utf-8"):
    if l.strip() and not l.startswith("#"):
        i, lang, text = l.rstrip("\n").split("\t", 2)
        lines[i] = (lang, text)

def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if not unicodedata.category(c).startswith(("P", "Z", "S")))

def cer(r, h):
    r, h = norm(r), norm(h)
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)] / max(1, len(r))

def asr(y, sr, lang):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tf:
        sf.write(tf.name, librosa.resample(y, orig_sr=sr, target_sr=16000), 16000, subtype="PCM_16")
        subprocess.run([cli, "-q", "-m", model, "-l", lang, "--threads", "6", "-o", tf.name + ".txt", tf.name],
                       capture_output=True, text=True)
        try:
            h = open(tf.name + ".txt", encoding="utf-8").read().strip().replace("\n", " ")
            os.remove(tf.name + ".txt")
        except FileNotFoundError:
            h = ""
    return h

files, pooled = [], {}
for fn in sorted(f for f in os.listdir(sdir) if f.endswith(".wav")):
    voice, lid = fn[:-4].rsplit("-", 2)[0], "-".join(fn[:-4].rsplit("-", 2)[1:])
    if lid not in lines:
        continue
    lang, text = lines[lid]
    y, sr = librosa.load(os.path.join(sdir, fn), sr=None)
    yt, _ = librosa.effects.trim(y, top_db=35)
    f0, vf, _ = librosa.pyin(y, fmin=60, fmax=500, sr=sr, frame_length=1024)
    f0 = f0[vf & ~np.isnan(f0)]
    hyp = asr(y, sr, lang)
    files.append(dict(file=fn, voice=voice, lang=lang, line=lid, audio_s=len(y) / sr, speech_s=len(yt) / sr,
                      f0=np.median(f0), f0_10=np.percentile(f0, 10), f0_90=np.percentile(f0, 90),
                      cps=len(norm(text)) / (len(yt) / sr), cer=cer(text, hyp), hyp=hyp, f0s=f0))
    pooled.setdefault(voice, []).append(yt)
    print(fn, f"{files[-1]['f0']:.0f} Hz", f"cer {files[-1]['cer']:.3f}", hyp, file=sys.stderr, flush=True)

with open(outp + ".files.tsv", "w", encoding="utf-8") as f:
    f.write("file\tlang\taudio_s\tspeech_s\tf0_median_hz\tf0_p10_hz\tf0_p90_hz\tchars_per_s\tcer\ttranscript\n")
    for r in files:
        f.write(f"{r['file']}\t{r['lang']}\t{r['audio_s']:.2f}\t{r['speech_s']:.2f}\t{r['f0']:.0f}\t{r['f0_10']:.0f}\t"
                f"{r['f0_90']:.0f}\t{r['cps']:.1f}\t{r['cer']:.3f}\t{r['hyp']}\n")

def spec(ys):
    y = np.concatenate(ys)
    m = librosa.feature.melspectrogram(y=y, sr=24000, n_fft=1024, hop_length=256, n_mels=64)
    e = m.sum(0); m = m[:, e > np.percentile(e, 30)]          # speech frames only
    ltas = 10 * np.log10(m.mean(1) + 1e-10); ltas -= ltas.mean()
    mf = librosa.feature.mfcc(S=librosa.power_to_db(m), n_mfcc=13)[1:].mean(1)
    return ltas, mf

def vec(name):
    if "_" in name and "x" in name and not os.path.exists(os.path.join(VDIR, name + ".pt")):
        # A blend as the render script names it: a x0.7 _ b x0.3.
        import re
        parts = re.findall(r"([a-z]+_[a-z]+)x([0-9.]+)", name)
        if parts:
            tot = sum(float(w) for _, w in parts)
            return sum(vec(n) * (float(w) / tot) for n, w in parts)
    p = os.path.join(VDIR, name + ".pt")
    return torch.load(p, weights_only=True).squeeze(1).mean(0).numpy() if os.path.exists(p) else None

def cos(a, b):
    return float(a @ b / np.linalg.norm(a) / np.linalg.norm(b))

rs, rv = spec(pooled[ref]), vec(ref)
with open(outp + ".voices.tsv", "w", encoding="utf-8") as f:
    f.write("voice\tlang\tf0_median_hz\tf0_p10_hz\tf0_p90_hz\tchars_per_s\tcer_mean\tcos_all\tcos_timbre\tcos_prosody\tltas_rms_db\tmfcc_dist\n")
    for v in pooled:
        rows = [r for r in files if r["voice"] == v]
        f0 = np.concatenate([r["f0s"] for r in rows])
        s = spec(pooled[v]); vv = vec(v)
        c = (cos(vv, rv), cos(vv[:128], rv[:128]), cos(vv[128:], rv[128:])) if vv is not None else ("", "", "")
        fm = lambda x: f"{x:.3f}" if x != "" else "-"
        f.write(f"{v}\t{rows[0]['lang']}\t{np.median(f0):.0f}\t{np.percentile(f0,10):.0f}\t{np.percentile(f0,90):.0f}\t"
                f"{np.mean([r['cps'] for r in rows]):.1f}\t{np.mean([r['cer'] for r in rows]):.3f}\t"
                f"{fm(c[0])}\t{fm(c[1])}\t{fm(c[2])}\t{np.sqrt(np.mean((s[0]-rs[0])**2)):.2f}\t{np.linalg.norm(s[1]-rs[1]):.1f}\n")
print("wrote", outp + ".files.tsv", outp + ".voices.tsv", file=sys.stderr)
