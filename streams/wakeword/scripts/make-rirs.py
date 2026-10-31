"""Simulated room impulse responses (pyroomacoustics, image source method).

    make-rirs.py OUTDIR N SEED

Shoebox rooms from a small office to a large living room, RT60 0.15-0.9 s,
source 0.5-4 m from the microphone. 16 kHz float WAVs, normalised to unit
peak. Simulated instead of recorded so the augmentation data carries no
licence of its own.
"""
import sys
from pathlib import Path

import numpy as np
import pyroomacoustics as pra
import soundfile as sf


def main():
    out, n, seed = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    k = 0
    while k < n:
        dims = np.array([rng.uniform(2.5, 8), rng.uniform(2.5, 7), rng.uniform(2.3, 3.5)])
        rt60 = rng.uniform(0.15, 0.9)
        try:
            e_abs, max_order = pra.inverse_sabine(rt60, dims)
        except ValueError:
            continue
        room = pra.ShoeBox(dims, fs=16000, materials=pra.Material(e_abs), max_order=min(max_order, 20))
        mic = np.array([rng.uniform(0.3, dims[0] - 0.3), rng.uniform(0.3, dims[1] - 0.3), rng.uniform(0.7, 1.3)])
        for _ in range(20):
            d = rng.uniform(0.5, 4.0)
            th, ph = rng.uniform(0, 2 * np.pi), rng.uniform(-0.3, 0.5)
            src = mic + d * np.array([np.cos(th) * np.cos(ph), np.sin(th) * np.cos(ph), np.sin(ph)])
            if np.all(src > 0.2) and np.all(src < dims - 0.2):
                break
        else:
            continue
        room.add_source(src)
        room.add_microphone(mic)
        room.compute_rir()
        h = np.asarray(room.rir[0][0], dtype=np.float32)
        h = h[np.argmax(np.abs(h) > 1e-4 * np.abs(h).max()):]
        h = h[: int(16000 * min(1.2, rt60 * 1.5 + 0.1))]
        sf.write(out / f"rir-{k:04d}.wav", h / np.abs(h).max(), 16000, subtype="FLOAT")
        k += 1


if __name__ == "__main__":
    main()
