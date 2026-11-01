#!/usr/bin/env python3
"""Compare two directories of 24 kHz mono WAVs (same names): waveform SNR,
STFT-magnitude SNR and log-spectral distance (frames within 60 dB of the
loudest), as kokoro-compare.py.   wav-compare.py REF_DIR TEST_DIR"""
import glob, os, sys, wave
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
kc = import_module('kokoro-compare')

def rd(p):
    with wave.open(p) as f:
        return np.frombuffer(f.readframes(f.getnframes()), '<i2').astype(np.float32) / 32768

rows = []
for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.wav'))):
    q = os.path.join(sys.argv[2], os.path.basename(p))
    if not os.path.exists(q):
        continue
    a, b = rd(p), rd(q)
    n = min(len(a), len(b))
    ms, lsd = kc.spec_metrics(a[:n], b[:n])
    rows.append((os.path.basename(p)[:-4], kc.snr(a[:n], b[:n]), ms, lsd, len(a), len(b)))
    print('%-10s SNR %6.1f dB  |STFT| SNR %5.1f dB  LSD %5.2f dB  len %d/%d' % rows[-1])
r = np.array([x[1:4] for x in rows])
print('mean       SNR %6.1f dB  |STFT| SNR %5.1f dB  LSD %5.2f dB  (%d lines)' % (*r.mean(0), len(rows)))
