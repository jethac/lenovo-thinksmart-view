#!/usr/bin/env python3
"""Check Qwen3-ASR streaming (incremental conv stem) against the offline path.

    laptop-stream-check.py [--chunk-ms 160] [--langs en,ja,zh] [--model GGUF]

For every clip of work/testset/cmd-LANG, runs transcribe-cli (work/build-native)
once offline and once through the streaming API, each with its own
TRANSCRIBE_DUMP_DIR, and compares the transcript and the dumped mel
(enc.mel.in), conv-stem output (enc.subsample.out) and encoder output
(enc.proj.out): max abs difference and bitwise equality. Also reports how many
chunks went through the conv stem during feed and how many were re-run at
finalize because the utterance max rose after them.
"""
import argparse
import array
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(HERE, "work/build-native/bin/transcribe-cli")
TENSORS = ["enc.mel.in", "enc.subsample.out", "enc.proj.out"]


def run(model, wav, lang, dump, chunk_ms):
    lst = os.path.join(dump, "list")
    with open(lst, "w") as f:
        f.write(wav + "\n")
    cmd = [CLI, "-m", model, "-l", lang, "--threads", "8", "--batch", lst, "--batch-jsonl"]
    if chunk_ms:
        cmd += ["--stream-chunk-ms", str(chunk_ms)]
    env = dict(os.environ, TRANSCRIBE_DUMP_DIR=dump, TRANSCRIBE_PERF_DEBUG="1")
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, check=True)
    rec = [json.loads(l) for l in p.stdout.splitlines() if l.startswith('{"file"')][0]
    m = re.search(r"(\d+) of (\d+) chunks through the conv stem during feed \((\d+) re-runs.*?"
                  r"at finalize: \d+ chunks \((\d+) re-run", p.stderr)
    return rec["text"], (tuple(int(x) for x in m.groups()) if m else None)


def load(path):
    a = array.array("f")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chunk-ms", type=int, default=160)
    ap.add_argument("--langs", default="en,ja,zh")
    ap.add_argument("--model", default=os.path.join(
        HERE, "downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf"))
    args = ap.parse_args()
    bad = 0
    tot = dict(clips=0, same_text=0, feed=0, chunks=0, rerun_feed=0, rerun=0)
    worst = {t: 0.0 for t in TENSORS}
    tmp = os.path.join(HERE, "work/tmp")  # the dumps are large; keep them off /tmp
    os.makedirs(tmp, exist_ok=True)
    for lang in args.langs.split(","):
        d = os.path.join(HERE, "work/testset", f"cmd-{lang}")
        for w in sorted(x for x in os.listdir(d) if x.endswith(".wav")):
            wav = os.path.join(d, w)
            with tempfile.TemporaryDirectory(dir=tmp) as a, tempfile.TemporaryDirectory(dir=tmp) as b:
                t_off, _ = run(args.model, wav, lang, a, 0)
                t_str, ch = run(args.model, wav, lang, b, args.chunk_ms)
                diffs = {}
                for t in TENSORS:
                    x, y = load(os.path.join(a, t + ".f32")), load(os.path.join(b, t + ".f32"))
                    diffs[t] = max(abs(p - q) for p, q in zip(x, y)) if len(x) == len(y) else float("inf")
                    diffs[t + "_bitwise"] = x.tobytes() == y.tobytes()
                    worst[t] = max(worst[t], diffs[t])
            tot["clips"] += 1
            tot["same_text"] += t_off == t_str
            if ch:
                tot["feed"] += ch[0]
                tot["chunks"] += ch[1]
                tot["rerun_feed"] += ch[2]
                tot["rerun"] += ch[3]
            ok = t_off == t_str and all(diffs[t + "_bitwise"] for t in TENSORS)
            bad += not ok
            print(f"{'ok ' if ok else 'BAD'} {lang} {w} chunks(feed/total/rerun during feed/at finalize)={ch} "
                  + " ".join(f"{t}={diffs[t]:.3g}" for t in TENSORS), flush=True)
            if t_off != t_str:
                print(f"    offline: {t_off}\n    stream:  {t_str}")
    print(f"clips {tot['clips']}, identical transcripts {tot['same_text']}, "
          f"chunks {tot['chunks']} ({tot['feed']} during feed; re-runs: {tot['rerun_feed']} during feed, "
          f"{tot['rerun']} at finalize), "
          "max abs diff " + " ".join(f"{t}={worst[t]:.3g}" for t in TENSORS))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
