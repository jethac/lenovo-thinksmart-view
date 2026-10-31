"""Augment clips into 2 s windows and compute openWakeWord features.

    make-features.py OUT.npy MODE COPIES SEED SPLIT DIR...

MODE:
  pos      the clip ends 0-250 ms before the end of the window (what the
           detector sees the moment the phrase is complete)
  neg      near misses: once end-aligned like pos, once at a random offset
  partial  the first 45-70 % of a positive clip, end-aligned (the phrase
           not yet finished must not fire)
  bg       background only (noise or music, no speech clip)
  clean    pos without augmentation (level only), for test reports
  utt      test only: per clip, the 4 consecutive windows (80 ms apart) a
           streaming detector sees once the phrase has ended (the first
           ending 0-80 ms after it); utt-clean the same without augmentation. Output
           (N*4, 16, 96), grouped by clip
SPLIT: train or test (picks RIRs and noise files; test ones are never
used in training).

Features come from straylight-listen's own front end (`--windows`), each
window from a cold start: 33280 samples (2.08 s) give exactly the 16
embeddings (16 x 96) the classifier sees in the daemon, ending where the
daemon's would. Output: float16 array (N, 16, 96).

Augmentation, per window: trim silence; random parametric EQ (p 0.3) and
low-pass (p 0.2); room reverb (p 0.6); speech level -50 to -12 dBFS RMS;
background noise or music at -3 to 25 dB SNR (p 0.8); coloured noise
(p 0.3); a mic-like noise floor (-85 to -65 dBFS) always.
"""
import hashlib
import os
import subprocess
import tempfile
import random
import sys
from math import gcd
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import fftconvolve, lfilter, resample_poly, butter

W = Path(__file__).resolve().parent.parent / "work"
D = Path(__file__).resolve().parent.parent / "downloads"
SR = 16000
WIN = 33280
LISTEN = Path(os.environ.get("STRAYLIGHT_LISTEN", "/home/jethac/Projects/straylight-voice"))
BIN = LISTEN / "listen/target/release/straylight-listen"
FRONTEND = LISTEN / "out/listen/frontend.slt"
DUMMY = LISTEN / "out/listen/dummy.slt"


def embed(audio):
    """int16 (N, WIN) -> float16 (N, 16, 96) via straylight-listen --windows."""
    with tempfile.TemporaryDirectory(dir=D / "tmp") as td:
        wav, emb = Path(td) / "w.wav", Path(td) / "w.emb"
        sf.write(wav, audio.reshape(-1), SR, subtype="PCM_16")
        subprocess.run([str(BIN), "--frontend", str(FRONTEND), "--model", str(DUMMY), "--input", str(wav),
                        "--windows", str(WIN), "--dump-embeddings", str(emb)], check=True,
                       stderr=subprocess.DEVNULL)
        return np.fromfile(emb, "<f4").reshape(-1, 16, 96).astype(np.float16)


def is_test(p):
    return int(hashlib.md5(p.name.encode()).hexdigest(), 16) % 10 == 0


def bg_files(split):
    # BG_SET: directories under work/ to draw background from (default noise
    # and music; "bg-speech" gives speech-only windows for mode bg).
    files = []
    for d in os.environ.get("BG_SET", "bg-noise bg-music").split():
        files += sorted((W / d).glob("*.wav"))
    return [f for f in files if is_test(f) == (split == "test")]


def load(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if sr != SR:
        g = gcd(sr, SR)
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return x


def trim(x, db=-40):
    if len(x) == 0:
        return x
    env = np.convolve(np.abs(x), np.ones(160) / 160, mode="same")
    thr = env.max() * 10 ** (db / 20)
    idx = np.nonzero(env > thr)[0]
    if len(idx) == 0:
        return x
    a, b = max(0, idx[0] - 800), min(len(x), idx[-1] + 800)
    return x[a:b]


def rms_db(x):
    return 10 * np.log10(np.mean(x.astype(np.float64) ** 2) + 1e-12)


def peaking(x, f0, gain_db, q):
    a = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / SR
    al = np.sin(w0) / (2 * q)
    b = [1 + al * a, -2 * np.cos(w0), 1 - al * a]
    aa = [1 + al / a, -2 * np.cos(w0), 1 - al / a]
    return lfilter(b, aa, x).astype(np.float32)


def colored(n, rng):
    beta = rng.choice([0.0, 1.0, 2.0])  # white, pink, brown
    f = np.fft.rfftfreq(n, 1 / SR)
    f[0] = f[1]
    spec = (rng.standard_normal(len(f)) + 1j * rng.standard_normal(len(f))) / f ** (beta / 2)
    y = np.fft.irfft(spec, n).astype(np.float32)
    return y / (np.std(y) + 1e-9)


class Aug:
    def __init__(self, split, seed):
        self.rirs = sorted((W / f"rirs-{split}").glob("*.wav"))
        self.bgs = bg_files(split)
        self.rng = np.random.default_rng(seed)
        self.bg_cache = {}

    def bg(self, n):
        f = self.bgs[self.rng.integers(len(self.bgs))]
        if f not in self.bg_cache:
            if len(self.bg_cache) > 64:
                self.bg_cache.pop(next(iter(self.bg_cache)))
            self.bg_cache[f] = load(f)
        x = self.bg_cache[f]
        if len(x) < n:
            x = np.tile(x, n // max(1, len(x)) + 1)
        s = self.rng.integers(0, len(x) - n + 1)
        y = x[s:s + n]
        return y / (np.sqrt(np.mean(y ** 2)) + 1e-9)

    def speech(self, x, augment=True):
        r = self.rng
        if augment:
            if r.random() < 0.3:
                for _ in range(r.integers(1, 4)):
                    x = peaking(x, r.uniform(100, 6000), r.uniform(-8, 8), r.uniform(0.5, 2))
            if r.random() < 0.2:
                b, a = butter(4, r.uniform(3000, 7500) / (SR / 2))
                x = lfilter(b, a, x).astype(np.float32)
            if r.random() < 0.6 and self.rirs:
                h, _ = sf.read(self.rirs[r.integers(len(self.rirs))], dtype="float32")
                y = fftconvolve(x, h)[: len(x) + int(0.3 * SR)]
                x = (y * np.sqrt(np.sum(x ** 2) / (np.sum(y ** 2) + 1e-9))).astype(np.float32)
        return x

    def window(self, clip, end_gap, augment=True, n=WIN):
        """n samples with clip ending end_gap samples before the end."""
        r = self.rng
        out = np.zeros(n, np.float32)
        if clip is not None:
            if len(clip) > n - end_gap:
                clip = clip[-(n - end_gap):]
            s = n - end_gap - len(clip)
            out[s:s + len(clip)] = clip
            act = clip[np.abs(clip) > 0.05 * np.abs(clip).max()] if np.abs(clip).max() > 0 else clip
            level = rms_db(act) if len(act) else -100
            target = r.uniform(-50, -12)
            out *= 10 ** ((target - level) / 20)
            sp_db = target
        else:
            sp_db = r.uniform(-50, -15)
        if augment:
            if clip is None or r.random() < 0.8:
                snr = r.uniform(-3, 25) if clip is not None else 0
                out += self.bg(n) * 10 ** ((sp_db - snr) / 20)
            if r.random() < 0.3:
                out += colored(n, r) * 10 ** ((sp_db - r.uniform(10, 40)) / 20)
        out += r.standard_normal(n).astype(np.float32) * 10 ** (r.uniform(-85, -65) / 20)
        peak = np.abs(out).max()
        if peak > 0.99:
            out *= 0.99 / peak
        return (out * 32767).astype(np.int16)


def work(args):
    paths, mode, copies, seed, split = args
    aug = Aug(split, seed)
    r = aug.rng
    res = []
    for p in paths:
        x = trim(load(p)) if p is not None else None
        for _ in range(copies):
            if mode == "bg":
                res.append(aug.window(None, 0))
                continue
            y = aug.speech(x, augment=(mode not in ("clean", "utt-clean")))
            if mode == "partial":
                cut = int(len(x) * r.uniform(0.45, 0.7))
                y = aug.speech(x[:cut])
                res.append(aug.window(y, int(r.uniform(0, 0.25) * SR)))
            elif mode in ("utt", "utt-clean"):
                # Window j ends j * 80 ms (plus 0-80 ms) after the phrase does.
                gap = 3 * 1280 + int(r.uniform(0, 1280))
                long = aug.window(y, gap, augment=(mode == "utt"), n=WIN + 3 * 1280)
                for j in range(4):
                    res.append(long[j * 1280:j * 1280 + WIN])
            elif mode == "neg":
                res.append(aug.window(y, int(r.uniform(0, 0.25) * SR)))
                res.append(aug.window(y, int(r.uniform(0.25, 1.2) * SR)))
            else:
                res.append(aug.window(y, int(r.uniform(0, 0.25) * SR), augment=(mode != "clean")))
    return embed(np.stack(res)) if res else np.zeros((0, 16, 96), np.float16)


def main():
    out, mode, copies, seed, split = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    if mode == "bg":
        n = int(sys.argv[6])
        paths = [None] * n
    else:
        paths = []
        for d in sys.argv[6:]:
            paths += sorted(Path(d).glob("*.wav"))
    random.Random(seed).shuffle(paths)
    chunks = [paths[i:i + 200] for i in range(0, len(paths), 200)]
    outs = []
    with Pool(int(os.environ.get("NPROC", "10"))) as pool:
        for k, f in enumerate(pool.imap(work, [(c, mode, copies, seed * 1000 + i, split)
                                                 for i, c in enumerate(chunks)])):
            outs.append(f)
            if k % 10 == 0:
                print(f"{out}: {k + 1}/{len(chunks)}", flush=True)
    X = np.concatenate(outs)
    assert X.shape[1:] == (16, 96), X.shape
    np.save(out, X)
    print(out, X.shape)


if __name__ == "__main__":
    main()
