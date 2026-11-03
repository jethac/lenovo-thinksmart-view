#!/usr/bin/env python3
"""Harmonicity between 2 and 4 kHz (Paradee's buzz measure): in steady
voiced frames, the energy on multiples of the pitch against the energy
halfway between them, in dB (higher: cleaner harmonics; Paradee reports
Kokoro 3.1 dB, its buzzy 1.0 decoder 1.3 dB).   harmonicity.py DIR..."""
import glob, os, sys
import librosa, numpy as np

for d in sys.argv[1:]:
    v = []
    for f in sorted(glob.glob(os.path.join(d, "*.wav")))[:20]:
        y, sr = librosa.load(f, sr=24000)
        f0, vf, _ = librosa.pyin(y, fmin=70, fmax=500, sr=sr, frame_length=2048, hop_length=512)
        S = np.abs(librosa.stft(y, n_fft=2048, hop_length=512)) ** 2
        fr = librosa.fft_frequencies(sr=sr, n_fft=2048)
        band = (fr >= 2000) & (fr < 4000)
        for t in range(1, min(S.shape[1], len(f0)) - 1):
            if not (vf[t - 1] and vf[t] and vf[t + 1]) or np.isnan(f0[t]):
                continue
            r = fr[band] / f0[t]; fracd = np.abs(r - np.round(r))
            h, m = S[band, t][fracd < 0.15].sum(), S[band, t][np.abs(fracd - 0.5) < 0.15].sum()
            if h > 0 and m > 0:
                v.append(10 * np.log10(h / m))
    print(f"{d}: {np.mean(v):.2f} dB over {len(v)} frames")
