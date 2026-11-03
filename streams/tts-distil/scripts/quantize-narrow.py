#!/usr/bin/env python3
"""Static uint8 quantisation (QOperator: QLinearConv / QLinearMatMul, as
onnx-community's Kokoro uint8) of an exported narrow student, calibrated
on lines of a phoneme TSV through the voice's own style rows.

    quantize-narrow.py MODEL.onnx VOICE.bin CONFIG.json PHON.tsv OUT.onnx [--ops Conv,MatMul]
"""
import argparse, json, os, tempfile
import numpy as np
from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static
from onnxruntime.quantization.shape_inference import quant_pre_process

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("voice"); ap.add_argument("config"); ap.add_argument("phon"); ap.add_argument("out")
ap.add_argument("--ops", default="Conv,MatMul")
ap.add_argument("--n", type=int, default=24)
a = ap.parse_args()
voc = json.load(open(a.config))["vocab"]
pack = np.fromfile(a.voice, "<f4").reshape(-1, 256)
rows = [l.rstrip("\n").split("\t") for l in open(a.phon, encoding="utf-8") if not l.startswith("#")]


class Reader(CalibrationDataReader):
    def __init__(self):
        self.it = iter(rows[:a.n])

    def get_next(self):
        f = next(self.it, None)
        if f is None:
            return None
        ids = [0] + [voc[c] for c in f[2] if c in voc][:510] + [0]
        return {"input_ids": np.array([ids], np.int64), "style": pack[len(ids) - 3][None], "speed": np.ones(1, np.float32)}


with tempfile.TemporaryDirectory() as d:
    pre = os.path.join(d, "pre.onnx")
    quant_pre_process(a.model, pre, skip_symbolic_shape=True)
    quantize_static(pre, a.out, Reader(), quant_format=QuantFormat.QOperator, activation_type=QuantType.QUInt8,
                    weight_type=QuantType.QUInt8, op_types_to_quantize=a.ops.split(","), per_channel=False)
print(a.out, os.path.getsize(a.out) / 1e6, "MB")
