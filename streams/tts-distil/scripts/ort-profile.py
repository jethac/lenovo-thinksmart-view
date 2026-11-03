#!/usr/bin/env python3
"""Summarise an ONNX Runtime profile (JSON): wall time per op type and per
part of the graph (text side, decoder trunk, generator), and the number of
node runs, which shows per-op overhead.   ort-profile.py PROFILE.json"""
import collections, json, sys

t = open(sys.argv[1]).read()
try:
    ev = json.loads(t)
except json.JSONDecodeError:  # cut off when the process exited: keep the complete events
    ev = []
    for l in t.splitlines():
        l = l.strip().lstrip("[").rstrip(",").rstrip("]")
        try:
            ev.append(json.loads(l))
        except json.JSONDecodeError:
            pass
by, part, n = collections.Counter(), collections.Counter(), collections.Counter()
runs = [e for e in ev if e.get("cat") == "Session" and e["name"] == "model_run"]
for e in ev:
    if e.get("cat") == "Node" and e["name"].endswith("_kernel_time"):
        nm, op = e["name"], e["args"]["op_name"]
        by[op] += e["dur"]; n[op] += 1
        part["generator" if "generator" in nm else "decoder trunk" if "decoder" in nm else "text side"] += e["dur"]
tot = sum(by.values())
print(f"{len(runs)} runs, {sum(r['dur'] for r in runs) / 1e6:.2f} s in model_run, {tot / 1e6:.2f} s in kernels, {sum(n.values())} node runs")
for k, v in part.most_common():
    print(f"  {k:14s} {v / tot * 100:5.1f} %")
for k, v in by.most_common(15):
    print(f"  {k:24s} {v / tot * 100:5.1f} %  {n[k]:6d} runs  {v / n[k]:8.0f} us each")
