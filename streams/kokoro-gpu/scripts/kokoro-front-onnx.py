#!/usr/bin/env python3
"""Cut a Kokoro ONNX export (with the durations output) at the decoder.

    kokoro-front-onnx.py IN.onnx OUT.onnx

OUT has the inputs of IN and the outputs asr [1,512,T], f0 [1,2T], n [1,2T]
and durations: the text encoder, prosody predictor and alignment only. The
decoder (about 85 % of the model's time and 2/3 of its weights) runs on the
GPU instead. Output order: asr, f0, n, durations.
"""
import sys
import onnx
from onnx import helper, TensorProto
from onnx.utils import Extractor

src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
g = m.graph
names = {o for n in g.node for o in n.output}
prod = {o: n for n in g.node for o in n.output}
want = ['/encoder/MatMul_1_output_0', '/encoder/Reshape_output_0', '/encoder/Reshape_1_output_0']
for i, w in enumerate(want):
    if w in names:
        continue
    # uint8 export: F0 and N cross as uint8 (QLinearConv -> Squeeze -> Reshape);
    # dequantize with the conv's output scale and zero point.
    q = w + '_QuantizeInput_quantized'
    assert q in names, w
    n = prod[q]
    while n.op_type in ('Reshape', 'Squeeze', 'Unsqueeze'):
        n = prod[n.input[0]]
    assert n.op_type == 'QLinearConv', n.op_type
    g.node.append(helper.make_node('DequantizeLinear', [q, n.input[6], n.input[7]], [w], name=w + '_dq'))
    names.add(w)
dur = g.output[1].name if len(g.output) > 1 else None
assert dur, 'IN has no durations output (kokoro-onnx-durations.py)'
outs = want + [dur]
# Extractor needs value_info for the outputs; shapes are dynamic.
vi = {v.name for v in list(g.value_info) + list(g.output)}
for w in want:
    if w not in vi:
        g.value_info.append(helper.make_tensor_value_info(w, TensorProto.FLOAT, None))
e = Extractor(m)
f = e.extract_model([i.name for i in g.input], outs)
for o, nm in zip(f.graph.output, ['asr', 'f0', 'n', 'durations']):
    pass  # names kept; the runtime reads outputs by position
onnx.save(f, dst)
ops = {}
for n in f.graph.node:
    ops[n.op_type] = ops.get(n.op_type, 0) + 1
print(dst, 'nodes', len(f.graph.node), 'outputs', [o.name for o in f.graph.output])
