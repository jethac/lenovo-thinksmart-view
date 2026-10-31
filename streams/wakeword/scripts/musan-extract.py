"""MUSAN parquet shards -> 16 kHz mono 16-bit WAVs.

    musan-extract.py OUTDIR SHARD.parquet...
"""
import io
import sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
from scipy.signal import resample_poly


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for shard in sys.argv[2:]:
        pf = pq.ParquetFile(shard)
        for g in range(pf.num_row_groups):
            for row in pf.read_row_group(g, columns=["audio", "path"]).to_pylist():
                name = row["path"].replace("/", "_")
                f = out / name
                if f.exists():
                    continue
                x, sr = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32", always_2d=True)
                x = x.mean(axis=1)
                if sr != 16000:
                    from math import gcd
                    g_ = gcd(sr, 16000)
                    x = resample_poly(x, 16000 // g_, sr // g_).astype(np.float32)
                sf.write(f, np.clip(x, -1, 1), 16000, subtype="PCM_16")


if __name__ == "__main__":
    main()
