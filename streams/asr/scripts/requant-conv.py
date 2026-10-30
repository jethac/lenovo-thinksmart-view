#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gguf", "numpy"]
# ///
"""Copy a Qwen3-ASR GGUF, storing enc.conv.1/2.weight as 2D Q8_0 matrices.

    requant-conv.py IN.gguf OUT.gguf

The 4D F32 kernels [KW=3, KH=3, IC, OC] become [KW*KH*IC, OC] Q8_0 (rows are
contiguous per output channel, so this is a reshape plus quantisation). Needs
the transcribe.cpp encoder change that runs 2D conv weights as mul_mat with
the weight as src0. Everything else is copied unchanged."""
import sys
import numpy as np
import gguf

TARGETS = {"enc.conv.1.weight", "enc.conv.2.weight"}
src, dst = sys.argv[1], sys.argv[2]
r = gguf.GGUFReader(src)
arch = r.fields[gguf.Keys.General.ARCHITECTURE].contents()
w = gguf.GGUFWriter(dst, arch=arch, endianess=r.endianess)
for f in r.fields.values():
    if f.name == gguf.Keys.General.ARCHITECTURE or f.name.startswith("GGUF."):
        continue
    vt = f.types[0]
    st = f.types[-1] if vt == gguf.GGUFValueType.ARRAY else None
    w.add_key_value(f.name, f.contents(), vt, sub_type=st)

out = []
for t in r.tensors:
    if t.name in TARGETS:
        assert t.tensor_type == gguf.GGMLQuantizationType.F32, (t.name, t.tensor_type)
        a = np.asarray(t.data, dtype=np.float32)          # numpy shape (OC, IC, KH, KW)
        a = a.reshape(a.shape[0], -1)                       # (OC, IC*KH*KW), KW fastest
        q = gguf.quants.quantize(a, gguf.GGMLQuantizationType.Q8_0)
        back = gguf.quants.dequantize(q, gguf.GGMLQuantizationType.Q8_0)
        err = float(np.max(np.abs(back - a))); rel = err / float(np.max(np.abs(a)))
        print(f"{t.name}: {list(a.shape)} F32 -> Q8_0, max abs err {err:.3g} ({rel:.2%} of max)")
        out.append((t.name, q, gguf.GGMLQuantizationType.Q8_0))
    else:
        out.append((t.name, t.data, t.tensor_type))
for name, data, ty in out:
    w.add_tensor_info(name, data.shape, data.dtype, data.nbytes, ty)
w.write_header_to_file(); w.write_kv_data_to_file(); w.write_ti_data_to_file()
for name, data, ty in out:
    w.write_tensor_data(data)
w.close()
print("wrote", dst)
