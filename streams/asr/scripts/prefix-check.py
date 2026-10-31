#!/usr/bin/env python3
"""Compare the runs of device-prefix-check.sh (or the same layout on the laptop).

    prefix-check.py DIR [LANGS]

For each language: transcripts and the max logit after each prompt (l0=,
bitwise) between the cache off and on, on and on through the streaming API,
and the same with a context prompt; T_prompt and the rows taken from the
cache per clip. Prompts of 64+ rows take ggml's tiled attention path.
"""
import json
import os
import re
import sys

d = sys.argv[1]
langs = (sys.argv[2] if len(sys.argv) > 2 else "en ja zh").split()


def load(l, m):
    p = os.path.join(d, f"prefix-check-{l}-{m}")
    texts = [json.loads(x)["text"] for x in open(p + ".jsonl") if x.startswith('{"file')]
    pre = [dict(re.findall(r"(\w+)=(\S+)", s)) for s in re.findall(r"qwen3_asr prefill: (.*)", open(p + ".err").read())]
    return texts, pre


for l in langs:
    r = {m: load(l, m) for m in ("off", "on", "son", "ctxoff", "ctxon", "ctxson")}
    for a, b in (("off", "on"), ("on", "son"), ("ctxoff", "ctxon"), ("ctxon", "ctxson")):
        (ta, pa), (tb, pb) = r[a], r[b]
        print(f"{l} {a:6} vs {b:6}: text {sum(x == y for x, y in zip(ta, tb))}/{len(ta)}, "
              f"logit bit-identical {sum(x['l0'] == y['l0'] for x, y in zip(pa, pb))}/{len(pa)}; "
              f"T_prompt {[int(x['T_prompt']) for x in pb]}, reused {[int(x['reused']) for x in pb]}")
