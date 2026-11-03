#!/usr/bin/env python3
"""UTMOS (SpeechMOS utmos22_strong, v1.2.0 through torch.hub; a predictor of
naturalness on a 1-5 scale) of every WAV in each directory; ids ending in
.seen (in the training corpus) are reported apart.

    utmos.py DIR...        (in the training image; TORCH_HOME caches the model)
"""
import glob, os, sys
import numpy as np, soundfile as sf, torch
import torchaudio

m = torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong", trust_repo=True).eval()
for d in sys.argv[1:]:
    s = {"held-out": [], "seen": []}
    for f in sorted(glob.glob(os.path.join(d, "*.wav"))):
        y, sr = sf.read(f, dtype="float32")
        if y.ndim > 1:
            y = y.mean(1)
        if sr != 16000:
            y = torchaudio.functional.resample(torch.from_numpy(y), sr, 16000).numpy()
        with torch.no_grad():
            v = m(torch.from_numpy(y)[None], 16000).item()
        s["seen" if ".seen" in os.path.basename(f) else "held-out"].append(v)
    print(d, " ".join(f"{k} {np.mean(v):.3f} (n={len(v)})" for k, v in s.items() if v), flush=True)
