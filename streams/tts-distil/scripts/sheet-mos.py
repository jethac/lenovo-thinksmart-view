#!/usr/bin/env python3
"""SHEET's SSL-MOS ("default": all7-sslmos-mdf-2337, trained on BVCC, SOMOS,
SingMOS, NISQA, TMHINT-QI, Tencent and PSTN, so Mandarin speech is in its
training data, unlike UTMOS's English-only BVCC) of every WAV in each
directory; ids ending in .seen reported apart.

    sheet-mos.py DIR...   (in the training image, PYTHONPATH with h5py,
                           humanfriendly, prettytable, s3prl; TORCH_HOME caches)
"""
import glob, os, sys
import numpy as np, soundfile as sf, torch, torchaudio

p = torch.hub.load("unilight/sheet:v0.1.0", "default", trust_repo=True)
for d in sys.argv[1:]:
    s = {"held-out": [], "seen": []}
    for f in sorted(glob.glob(os.path.join(d, "*.wav"))):
        y, sr = sf.read(f, dtype="float32")
        y = torch.from_numpy(y.mean(1) if y.ndim > 1 else y)
        if sr != 16000:
            y = torchaudio.functional.resample(y, sr, 16000)
        with torch.no_grad():
            v = float(p.predict(wav=y))
        s["seen" if ".seen" in os.path.basename(f) else "held-out"].append(v)
    print(d, " ".join(f"{k} {np.mean(v):.3f} (n={len(v)})" for k, v in s.items() if v), flush=True)
