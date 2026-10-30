#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Summarise scripts/device-stream-qwen.sh results: offline vs streaming.

    summarise-stream.py [QUANT] [THREADS] [LANGS]     e.g. Q4_K_M-convq8 8 en,ja,zh

Per language and mode: median latency after the end of the audio, median
audio length, CPU time during and after the audio (median per clip, and the
average number of busy cores while the audio arrives), the longest single
feed call, identical-transcript count between the modes, accuracy
(scripts/score.py), conv-stem chunk counts from the streaming log, and the
wake-up probe split into "while audio arrives" and "after the audio" phases.
"""
import json
import os
import re
import statistics as st
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(HERE, "work/results/device")


def jsonl(path):
    out = []
    for line in open(path, encoding="utf-8"):
        if line.startswith('{"file"'):
            out.append(json.loads(line))
    return out


def probe(path, rows):
    """Lateness samples split by phase: during audio, after audio (to final text)."""
    during, after = [], []
    spans = [(r["t_start_ms"], r["t_start_ms"] + r["audio_ms"], r["t_start_ms"] + r["audio_ms"] + r["latency_ms"])
             for r in rows]
    for line in open(path):
        t, late = map(float, line.split())
        for a, b, c in spans:
            if a <= t < b:
                during.append(late)
                break
            if b <= t < c:
                after.append(late)
                break
    return during, after


def pstat(x):
    if not x:
        return "-"
    x = sorted(x)
    return (f"p50 {x[len(x) // 2]:.1f} p99 {x[int(len(x) * 0.99)]:.1f} max {x[-1]:.0f} ms, "
            f">16 ms {100 * sum(v > 16 for v in x) / len(x):.1f} %")


def score(rows, lang):
    tsv = os.path.join(RES, f".score-{lang}.tsv")
    with open(tsv, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(os.path.basename(r["file"]).removesuffix(".wav") + "\t" + r["text"].replace("\t", " ") + "\n")
    refs = os.path.join(HERE, "work/testset", f"cmd-{lang}", "refs.tsv")
    out = subprocess.run([os.path.join(HERE, "scripts/score.py"), refs, tsv, lang], capture_output=True, text=True)
    os.remove(tsv)
    return out.stdout.split(" n=")[0].strip()


def main():
    q = sys.argv[1] if len(sys.argv) > 1 else "Q4_K_M-convq8"
    t = sys.argv[2] if len(sys.argv) > 2 else "8"
    langs = (sys.argv[3] if len(sys.argv) > 3 else "en,ja,zh").split(",")
    idle = [float(l.split()[1]) for l in open(os.path.join(RES, "stream-idle.probe.raw"))]
    print(f"idle probe: {pstat(idle)}")
    for lang in langs:
        rows = {m: jsonl(os.path.join(RES, f"stream-{q}-t{t}-{lang}-{m}.jsonl")) for m in ("offline", "stream")}
        same = sum(a["text"] == b["text"] for a, b in zip(rows["offline"], rows["stream"]))
        err = open(os.path.join(RES, f"stream-{q}-t{t}-{lang}-stream.err")).read()
        ch = [tuple(map(int, m)) for m in re.findall(
            r"(\d+) of (\d+) chunks through the conv stem during feed \((\d+) re-runs.*?"
            r"at finalize: (\d+) chunks \((\d+) re-run", err)]
        print(f"\n{lang}: {len(rows['stream'])} clips, identical transcripts {same}/{len(rows['stream'])}, "
              f"chunks {sum(c[1] for c in ch)} total, {sum(c[0] for c in ch)} during audio "
              f"(+{sum(c[2] for c in ch)} re-runs), {sum(c[3] for c in ch)} at finalize "
              f"({sum(c[4] for c in ch)} re-runs)")
        for m in ("offline", "stream"):
            r = rows[m]
            med = lambda k: st.median(x[k] for x in r)
            cores = st.median(x["cpu_during_ms"] / x["audio_ms"] for x in r)
            d, a = probe(os.path.join(RES, f"stream-{q}-t{t}-{lang}-{m}.probe.raw"), r)
            print(f"  {m:8s} audio {med('audio_ms') / 1000:.2f} s  latency {med('latency_ms') / 1000:.2f} s "
                  f"(max {max(x['latency_ms'] for x in r) / 1000:.2f})  encode {med('encode_ms'):.0f} ms  "
                  f"decode {med('decode_ms'):.0f} ms  CPU during {med('cpu_during_ms') / 1000:.2f} s "
                  f"({cores:.2f} cores)  after {med('cpu_after_ms') / 1000:.2f} s  "
                  f"total {st.median(x['cpu_during_ms'] + x['cpu_after_ms'] for x in r) / 1000:.2f} s  "
                  f"longest feed {max(x['feed_max_ms'] for x in r):.0f} ms  {score(r, lang)}")
            print(f"           probe during audio: {pstat(d)}")
            print(f"           probe after audio:  {pstat(a)}")


if __name__ == "__main__":
    main()
