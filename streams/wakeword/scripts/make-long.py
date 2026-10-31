"""Concatenate many audio files into long 16 kHz mono WAVs (for false-accept tests).

    make-long.py OUTPREFIX FILE...      or   make-long.py OUTPREFIX @LISTFILE

Writes OUTPREFIX-NN.wav of up to 30 minutes each, with 0.3 s of silence
between files, and prints the total duration.
"""
import sys
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

CHUNK = 30 * 60 * 16000


def main():
    prefix = sys.argv[1]
    files = sys.argv[2:]
    if len(files) == 1 and files[0].startswith("@"):
        files = [l.strip() for l in open(files[0][1:]) if l.strip()]
    Path(prefix).parent.mkdir(parents=True, exist_ok=True)
    buf, k, total = [], 0, 0
    gap = np.zeros(4800, np.float32)

    def flush():
        nonlocal buf, k
        if buf:
            sf.write(f"{prefix}-{k:02d}.wav", np.concatenate(buf), 16000, subtype="PCM_16")
            k += 1
            buf = []

    n = 0
    for f in files:
        x, sr = sf.read(f, dtype="float32", always_2d=True)
        x = x.mean(axis=1)
        if sr != 16000:
            g = gcd(sr, 16000)
            x = resample_poly(x, 16000 // g, sr // g).astype(np.float32)
        buf += [x, gap]
        n += len(x) + len(gap)
        total += len(x) + len(gap)
        if n >= CHUNK:
            flush()
            n = 0
    flush()
    print(f"{prefix}: {len(files)} files, {total / 16000 / 3600:.2f} h in {k} files")


if __name__ == "__main__":
    main()
