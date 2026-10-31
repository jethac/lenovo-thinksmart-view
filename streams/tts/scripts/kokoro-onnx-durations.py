#!/usr/bin/env python3
"""Add the duration predictor's output to a Kokoro ONNX export.

    kokoro-onnx-durations.py IN.onnx OUT.onnx

The onnx-community export returns only the waveform. The rounded, clipped
per-token durations (frames of 600 samples at 24 kHz) are the tensor that
feeds the alignment's CumSum; exposing it as a second output, "durations",
lets the player map playback time back to characters. Nothing else changes.
"""
import sys
import onnx
from onnx import helper, TensorProto

src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
g = m.graph
cum = [n for n in g.node if n.op_type == "CumSum" and n.name.startswith("/encoder/")]
assert len(cum) == 1, [n.name for n in cum]
prod = {o: n for n in g.node for o in n.output}
# CumSum <- Gather <- ... <- Clip(Round(Div(ReduceSum(Sigmoid)))).
seen, todo, clip = set(), [cum[0].input[0]], None
while todo and clip is None:
    t = todo.pop()
    n = prod.get(t)
    if n is None or n.name in seen:
        continue
    seen.add(n.name)
    if n.op_type == "Clip" and prod.get(n.input[0]) is not None and prod[n.input[0]].op_type == "Round":
        clip = n
        break
    todo.extend(n.input)
assert clip is not None, "no Clip(Round(...)) above the encoder's CumSum"
name = clip.output[0]
g.output.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, None))
g.output[-1].name = name
# Keep the tensor's own name (renaming would need rewiring); the runtime
# looks the output up by position.
onnx.save(m, dst)
print(f"{dst}: outputs {[o.name for o in g.output]}")
