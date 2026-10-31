#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Wake word + command test utterances for the voice pipeline, in work/testset/.

    make-testset.py

For each command clip of the ASR stream's sets (../asr/work/testset/cmd-{en,ja,zh},
15 each): 0.5 s of low-level room noise, a held-out "Hey Straylight" clip in
the same language (Magpie TTS, ../wakeword/work/clips/magpie-pos-test-<lang>),
a 350 ms pause, the command (edges trimmed), 2.5 s of noise. Wake and command
are each brought to a speech level of -22 dBFS (as in the ASR stream's phrase
set). Written twice: 16 kHz mono (file input) and 48 kHz stereo S16 (aplay on
hw:0,0). refs.tsv: id<TAB>wav16<TAB>reference<TAB>lang<TAB>wake_end_s<TAB>cmd_start_s<TAB>cmd_end_s.
"""
import os
import random

import numpy as np
import soundfile as sf

SR = 16000
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STREAMS = os.path.dirname(HERE)
CMD = os.path.join(STREAMS, "asr", "work", "testset")
WAKE = os.path.join(STREAMS, "wakeword", "work", "clips")
OUT = os.path.join(HERE, "work", "testset")
rng = np.random.default_rng(0)
NOISE_RMS = 0.002  # about -54 dBFS


def noise(n):
    w = rng.standard_normal(n + 2000)
    y = np.empty_like(w)
    acc = 0.0
    for i, v in enumerate(w):
        acc = 0.97 * acc + v
        y[i] = acc
    y = y[2000:]
    y -= y.mean()
    return (y / (np.sqrt((y ** 2).mean()) + 1e-12) * NOISE_RMS).astype(np.float32)


def load(path):
    a, sr = sf.read(path, dtype="float32", always_2d=True)
    assert sr == SR, (path, sr)
    return a.mean(axis=1)


def trim(a, margin_s=0.1):
    f = 320
    n = len(a) // f
    rms = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1)) + 1e-9
    on = np.nonzero(20 * np.log10(rms / rms.max()) > -35)[0]
    s = max(0, on[0] * f - int(margin_s * SR))
    e = min(len(a), (on[-1] + 1) * f + int(margin_s * SR))
    return a[s:e]


def level(a, target_db=-22.0):
    f = 320
    n = len(a) // f
    rms = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1))
    g = 10 ** ((target_db - 20 * np.log10(np.percentile(rms, 90) + 1e-9)) / 20)
    g = min(g, 0.95 / (np.abs(a).max() + 1e-9))
    return (a * g).astype(np.float32)


def resample48(a):
    # 16 -> 48 kHz: zero-stuff by 3 and a windowed-sinc low-pass at 7.6 kHz.
    up = np.zeros(len(a) * 3, dtype=np.float64)
    up[::3] = a * 3
    n = np.arange(-180, 181)
    h = np.sinc(2 * 7600 / 48000 * n) * 2 * 7600 / 48000 * np.kaiser(len(n), 8.0)
    return np.convolve(up, h, mode="same").astype(np.float32)


def main():
    os.makedirs(os.path.join(OUT, "16k"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "48k"), exist_ok=True)
    refs = open(os.path.join(OUT, "refs.tsv"), "w", encoding="utf-8")
    for lang in ("en", "ja", "zh"):
        rows = [l.rstrip("\n").split("\t", 2) for l in open(os.path.join(CMD, f"cmd-{lang}", "refs.tsv"), encoding="utf-8")]
        wakes = sorted(os.listdir(os.path.join(WAKE, f"magpie-pos-test-{lang}")))
        random.Random(lang).shuffle(wakes)
        for k, (cid, wav, ref) in enumerate(rows):
            wk = level(trim(load(os.path.join(WAKE, f"magpie-pos-test-{lang}", wakes[k])), 0.05))
            cmd = level(trim(load(wav)))
            parts = [noise(int(0.5 * SR)), wk, noise(int(0.35 * SR)), cmd, noise(int(2.5 * SR))]
            a = np.clip(np.concatenate(parts), -1, 1)
            wake_end = (len(parts[0]) + len(wk)) / SR
            c0 = wake_end + len(parts[2]) / SR
            c1 = c0 + len(cmd) / SR
            uid = f"{lang}-{k:02d}"
            p16 = os.path.join(OUT, "16k", uid + ".wav")
            sf.write(p16, a, SR, subtype="PCM_16")
            s = np.clip(resample48(a), -1, 1)
            sf.write(os.path.join(OUT, "48k", uid + ".wav"), np.stack([s, s], axis=1), 48000, subtype="PCM_16")
            refs.write(f"{uid}\t{p16}\t{ref}\t{lang}\t{wake_end:.3f}\t{c0:.3f}\t{c1:.3f}\n")
            print(f"{uid}: {len(a) / SR:.1f} s, wake {wakes[k]}, command {cid}")


main()
