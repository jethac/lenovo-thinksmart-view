#!/usr/bin/env python3
"""Where Kokoro's time goes: ONNX Runtime profile of one synthesis, summed
by top-level module (bert, text encoder, predictor, decoder stages).

    kokoro-profile.py MODEL.onnx REF.tsv ID [threads]
"""
import json, sys, collections, os, numpy as np, onnxruntime as ort
model, ref, want = sys.argv[1:4]
th = int(sys.argv[4]) if len(sys.argv) > 4 else 1
ids = next(l.split("\t")[3] for l in open(ref, encoding="utf-8") if l.startswith(want + "\t"))
ids = [0] + [int(x) for x in ids.split()] + [0]
voice = np.fromfile(os.path.join(os.path.dirname(__file__), "../downloads/kokoro/onnx-community/voices/af_heart.bin"), dtype=np.float32).reshape(-1, 256)
so = ort.SessionOptions(); so.intra_op_num_threads = th; so.enable_profiling = True
so.profile_file_prefix = os.path.join(os.environ.get("TMPDIR", "/tmp"), "kokoro-prof")
s = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
feed = {"input_ids": np.array([ids], np.int64), "style": voice[len(ids) - 3][None], "speed": np.ones(1, np.float32)}
s.run(None, feed)
p = s.end_profiling()
ev = [e for e in json.load(open(p)) if e.get("cat") == "Node" and e["name"].endswith("_kernel_time")]
by_mod, by_op = collections.Counter(), collections.Counter()
for e in ev:
    n = e["name"][:-12]
    parts = n.strip("/").split("/")
    key = "/".join(parts[:4]) if parts[0] == "decoder" else "/".join(parts[:2])
    by_mod[key] += e["dur"]; by_op[e["args"].get("op_name", "?")] += e["dur"]
tot = sum(by_mod.values())
print(f"total {tot/1e3:.0f} ms over {len(ev)} nodes")
for k, v in by_mod.most_common(25): print(f"{v/tot*100:5.1f} %  {v/1e3:8.1f} ms  {k}")
print()
for k, v in by_op.most_common(12): print(f"{v/tot*100:5.1f} %  {k}")
