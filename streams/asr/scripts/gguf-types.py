#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gguf"]
# ///
"""Tensor types and bytes per component (encoder vs decoder vs other) in a GGUF."""
import collections, sys
from gguf import GGUFReader
r = GGUFReader(sys.argv[1])
agg = collections.defaultdict(lambda: collections.Counter())
for t in r.tensors:
    n = t.name
    part = "encoder" if any(k in n for k in ("audio", "enc", "conv", "whisper")) else ("decoder" if any(k in n for k in ("blk.", "layers.", "token_embd", "output")) else "other")
    agg[part][t.tensor_type.name] += int(t.n_bytes)
for part, c in agg.items():
    tot = sum(c.values())
    print(f"{part:8s} {tot/2**20:7.1f} MiB  " + ", ".join(f"{k} {v/2**20:.1f}" for k, v in c.most_common()))
print("sample names:", [t.name for t in r.tensors[:3]], "...", [t.name for t in r.tensors[-3:]])
