#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "soundfile", "soxr"]
# ///
"""resample16k.py OUTDIR WAV...: each WAV as 16 kHz mono 16-bit in OUTDIR."""
import os
import sys

import numpy as np
import soundfile as sf
import soxr

out = sys.argv[1]
for f in sys.argv[2:]:
    x, sr = sf.read(f, dtype="float32", always_2d=True)
    y = soxr.resample(x.mean(axis=1), sr, 16000)
    sf.write(os.path.join(out, os.path.basename(f)), np.clip(y, -1, 1), 16000, subtype="PCM_16")
