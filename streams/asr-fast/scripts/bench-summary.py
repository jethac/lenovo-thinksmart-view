#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Summarise sla-bench JSONL (bench/sla-bench.cpp) per set.

    bench-summary.py RESULTS.jsonl... [--per-utt]

Sets: the command clips cmd-en/ja/zh (by the WAV's directory) and the phrase
set groups en, ja, zh, mx, lx-en/ja/zh (by id). Per set (medians unless
said otherwise):
- end: end of the last speech (VAD) to the final text, over utterances
  (as "end of speech to text" in ../asr/NOTES.md);
- final: the same per phrase (every phrase);
- live: live-text lag, the time a live-text event arrived minus the time
  the end of the audio it covers was fed, over events;
- gap: interval between successive live-text updates of a phrase;
- dec / flush: offline decode and online flush per phrase (ms);
- cpu: process CPU seconds per second of audio while the audio was fed, and
  after it (seconds per utterance);
- late: worst lateness of the 20 ms feeder against the real-time schedule
  (ms; the feeder runs the VAD, as the capture thread does);
- rss: file-backed / anonymous MiB at the end (max over the file);
- accuracy: corpus WER (en) or CER (others), as ../asr/scripts/score.py.
"""
import json
import os
import re
import statistics as st
import sys
from collections import defaultdict

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "..", "asr", "work", "testset")
EN, BASIC = EnglishTextNormalizer(), BasicTextNormalizer()

refs = {}
for d in ("cmd-en", "cmd-ja", "cmd-zh", "phrase"):
    for line in open(os.path.join(TS, d, "refs.tsv"), encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        refs[f[0]] = f[2]


def group(path):
    cid = os.path.basename(path)[:-4]
    d = os.path.basename(os.path.dirname(path))
    if d.startswith("cmd-"):
        return cid, d, d[4:]
    g = re.sub(r"-\d+$", "", cid)
    lang = g[3:] if g.startswith("lx-") else g
    return cid, g, ("en" if lang == "en" else "cjk")


def norm(t, lang):
    return EN(t) if lang == "en" else BASIC(t).replace(" ", "")


def rate(pairs, lang):
    r = [norm(a, lang) for a, _ in pairs]
    h = [norm(b, lang) for _, b in pairs]
    keep = [i for i, x in enumerate(r) if x]
    r, h = [r[i] for i in keep], [h[i] for i in keep]
    if not r:
        return float("nan")
    return (jiwer.process_words(r, h).wer if lang == "en" else jiwer.process_characters(r, h).cer) * 100


def med(v):
    v = [x for x in v if x is not None]
    return st.median(v) if v else float("nan")


def main():
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    per = "--per-utt" in sys.argv
    order, by = [], defaultdict(lambda: defaultdict(list))
    for fn in files:
        for line in open(fn, encoding="utf-8"):
            if not line.startswith("{"):
                continue
            u = json.loads(line)
            cid, g, lang = group(u["file"])
            if g not in order:
                order.append(g)
            b = by[g]
            b["lang"] = lang
            b["acc"].append((refs[cid], u["text"]))
            ph, parts = u["phrases"], u["partials"]
            for p in ph:
                b["final"].append(p["t_done"] - p["t_speech_end"])
                if p["dec"] > 0:
                    b["dec"].append(p["dec"])
                if p["enc"] > 0:
                    b["flush"].append(p["enc"])
                ts = [q["t"] for q in parts if q["i"] == p["i"] and q["t"] <= p["t_done"]]
                b["gap"].extend(y - x for x, y in zip(ts, ts[1:]))
                b["langs"].append(p["lang"])
            for q in parts:
                b["live"].append(q["t"] - q["t_cov"])
            if ph:
                b["end"].append(ph[-1]["t_done"] - ph[-1]["t_speech_end"])
            a = u["audio_ms"] / 1000
            b["cpu_a"].append(u["cpu_audio_s"] / a if a else None)
            b["cpu_after"].append(u["cpu_s"] - u["cpu_audio_s"])
            b["late"].append(u["late_max_ms"])
            b["over20"].append(u.get("late_over20", 0))
            b["rss"].append((u["rss_file_mb"], u["rss_anon_mb"]))
            b["n_ph"].append(len(ph))
            if per:
                print(cid, round(ph[-1]["t_done"] - ph[-1]["t_speech_end"]) if ph else "-", "|", u["text"])
    print("| set | utts | phrases | end | final | live | gap | dec | flush | cpu/s audio | cpu after | late max | rss file/anon | accuracy |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for g in order:
        b = by[g]
        lang = b["lang"]
        rf = max(x[0] for x in b["rss"])
        ra = max(x[1] for x in b["rss"])
        print(f"| {g} | {len(b['acc'])} | {sum(b['n_ph'])} | {med(b['end']) / 1000:.2f} s | {med(b['final']) / 1000:.2f} s | "
              f"{med(b['live']) / 1000:.2f} s | {med(b['gap']) / 1000:.2f} s | {med(b['dec']):.0f} | {med(b['flush']):.0f} | "
              f"{med(b['cpu_a']):.2f} | {med(b['cpu_after']):.2f} s | {max(b['late']):.0f} ms ({sum(b['over20'])}) | "
              f"{rf:.0f} / {ra:.0f} | {'WER' if lang == 'en' else 'CER'} {rate(b['acc'], lang):.2f} % |")


if __name__ == "__main__":
    main()
