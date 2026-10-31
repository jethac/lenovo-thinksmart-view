"""SNR of B against reference A (two 16-bit mono WAVs, compared over the shorter length)."""
import sys, wave
import numpy as np
def rd(p):
    with wave.open(p) as w: return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64)
a, b = rd(sys.argv[1]), rd(sys.argv[2]); n = min(len(a), len(b)); a, b = a[:n], b[:n]
e = np.sum((a - b) ** 2)
print(f"samples={n} snr_db={10*np.log10(np.sum(a**2)/e) if e else float('inf'):.1f} max_abs_diff={np.max(np.abs(a-b)):.0f}")
