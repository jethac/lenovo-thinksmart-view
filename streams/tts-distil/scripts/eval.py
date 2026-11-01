#!/usr/bin/env python3
"""Evaluation of the distilled voices against Kokoro (laptop).

    eval.py LINES.tsv REF_DIR TEST_DIR... > rows.tsv

For each <id>.wav in each directory (REF_DIR is Kokoro, the teacher):
Qwen3-ASR round trip (transcribe.cpp CLI, as streams/tts/scripts/rt-asr.py),
CER over normalised characters; median voiced F0 (pYIN); and for the test
directories the distance to the same line in REF_DIR after DTW on log-mel
frames: mel L1 (natural-log mel, 80 bins, 22.05 kHz analysis) and log-
spectral distance (dB, 513 bins), plus the duration ratio. Summary lines
(mean per directory and language) at the end, prefixed with '#'.
Environment: ASR_CLI, ASR_MODEL (defaults: the asr stream's build).
"""
import collections, os, subprocess, sys, tempfile, unicodedata
import librosa, numpy as np, soundfile as sf

CLI = os.environ.get("ASR_CLI", "/home/jethac/Projects/lenovo-8/streams/asr/work/build-native/bin/transcribe-cli")
MODEL = os.environ.get("ASR_MODEL", "/home/jethac/Projects/lenovo-8/streams/asr/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-Q8_0.gguf")
ALIAS = {"ja": "エーアイアンド", "zh": "诶爱安德", "en": "A-I and"}


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


def asr(y, lang):
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=os.environ.get("TMPDIR")) as tf:
        sf.write(tf.name, y, 16000, subtype="PCM_16")
        subprocess.run([CLI, "-q", "-m", MODEL, "-l", lang, "--threads", "8", "-o", tf.name + ".txt", tf.name],
                       capture_output=True)
        h = open(tf.name + ".txt", encoding="utf-8").read().strip() if os.path.exists(tf.name + ".txt") else ""
        if os.path.exists(tf.name + ".txt"):
            os.remove(tf.name + ".txt")
    return h.replace("\n", " ")


def feats(y):
    S = np.abs(librosa.stft(y, n_fft=1024, hop_length=256, win_length=1024)) + 1e-5
    M = librosa.feature.melspectrogram(S=S, sr=22050, n_mels=80, fmax=8000, power=1.0)
    return np.log(np.maximum(M, 1e-5)), 20 * np.log10(S)


def trim(y):
    yt, _ = librosa.effects.trim(y, top_db=40)
    return yt


def dist(a, b):
    ma, sa = feats(trim(a))
    mb, sb = feats(trim(b))
    _, wp = librosa.sequence.dtw(X=ma, Y=mb, metric="euclidean")
    i, j = wp[:, 0], wp[:, 1]
    mel = float(np.mean(np.abs(ma[:, i] - mb[:, j])))
    lsd = float(np.mean(np.sqrt(np.mean((sa[:, i] - sb[:, j]) ** 2, axis=0))))
    return mel, lsd


def main():
    lines, ref = sys.argv[1], sys.argv[2]
    dirs = [ref] + sys.argv[3:]
    text = {}
    for l in open(lines, encoding="utf-8"):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 3 and not l.startswith("#"):
            text[f[0]] = (f[1], f[2].replace("ai&", ALIAS[f[1]]))
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    print("dir\tid\tlang\taudio_s\tf0_hz\tcer\tmel_l1\tlsd_db\tdur_ratio\ttranscript")
    for d in dirs:
        dn = os.path.basename(d.rstrip("/"))
        for uid in sorted(text):
            p = os.path.join(d, uid + ".wav")
            if not os.path.exists(p):
                continue
            lang, ref_text = text[uid]
            y, _ = librosa.load(p, sr=22050)
            y16 = librosa.resample(y, orig_sr=22050, target_sr=16000)
            f0, vf, _ = librosa.pyin(y16, fmin=70, fmax=500, sr=16000)
            f0m = float(np.nanmedian(f0[vf])) if vf.any() else 0.0
            h = asr(y16, lang)
            c = cer(ref_text, h)
            mel = lsd = ratio = float("nan")
            rp = os.path.join(ref, uid + ".wav")
            if d != ref and os.path.exists(rp):
                yr, _ = librosa.load(rp, sr=22050)
                mel, lsd = dist(y, yr)
                ratio = len(trim(y)) / max(1, len(trim(yr)))
            for k, v in (("cer", c), ("mel", mel), ("lsd", lsd), ("ratio", ratio), ("f0", f0m)):
                by[(dn, lang)][k].append(v)
            print(f"{dn}\t{uid}\t{lang}\t{len(y) / 22050:.2f}\t{f0m:.0f}\t{c:.3f}\t{mel:.3f}\t{lsd:.2f}\t{ratio:.3f}\t{h}",
                  flush=True)
    for (dn, lang), m in sorted(by.items()):
        n = len(m["cer"])
        s = " ".join(f"{k} {np.nanmean(v):.3f}" for k, v in m.items() if not np.all(np.isnan(v)))
        print(f"# {dn} {lang} n={n} {s}")


main()
