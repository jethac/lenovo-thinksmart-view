#!/usr/bin/env python3
"""Render lines with an exported Kokoro student (model.onnx: input_ids,
speed and, if the graph takes it, style in; waveform and durations out)
through ONNX Runtime on the CPU, the way straylight-listen's Kokoro path
feeds it: Kokoro's token IDs, a 0 pad at each end, at most 510 tokens,
and the style row n - 1 of the voice's pack (voice.bin next to the model)
for n tokens.

    synth-paradee.py MODEL.onnx CONFIG.json PHON.tsv OUT_DIR [--threads N]

CONFIG.json is Kokoro's (for its vocabulary). Writes OUT_DIR/<id>.wav at 24 kHz.
"""
import argparse, json, os, time
import numpy as np, onnxruntime as ort, soundfile as sf

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("config"); ap.add_argument("phon"); ap.add_argument("out")
ap.add_argument("--threads", type=int, default=4)
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
voc = json.load(open(a.config))["vocab"]
so = ort.SessionOptions(); so.intra_op_num_threads = a.threads; so.inter_op_num_threads = 1
s = ort.InferenceSession(a.model, so, providers=["CPUExecutionProvider"])
names = [i.name for i in s.get_inputs()]
vb = os.path.join(os.path.dirname(a.model), "voice.bin")
pack = np.fromfile(vb, "<f4").reshape(-1, 256) if os.path.exists(vb) else None
ta = tt = 0.0
for l in open(a.phon, encoding="utf-8"):
    f = l.rstrip("\n").split("\t")
    if len(f) < 3 or l.startswith("#"):
        continue
    ids = [0] + [voc[c] for c in f[2] if c in voc][:510] + [0]
    feed = {"input_ids": np.array([ids], np.int64), "speed": np.ones(1, np.float32)}
    if "style" in names:
        n = len(ids) - 2
        feed["style"] = pack[min(n - 1, len(pack) - 1)][None] if pack is not None else np.zeros((1, 256), np.float32)
    t0 = time.time(); y = s.run(None, feed)[0].reshape(-1); el = time.time() - t0
    sf.write(os.path.join(a.out, f[0] + ".wav"), np.clip(y, -1, 1), 24000, subtype="PCM_16")
    ta += len(y) / 24000; tt += el
print(f"total {ta:.1f} s audio, RTF {tt / max(ta, 1e-9):.3f} ({a.threads} threads)")
