#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Summarise voice pipeline runs: the `utterance` log lines of straylight-listen
matched to work/testset/refs.tsv.

    summarise.py LOG [--per-utt] [--only REGEX]

LOG is a device-file.sh log (file input: utterances in file order, each
followed by its file's JSON line) or an acoustic-run log (lines
`# clip ID` before each clip's utterance). Times in ms; medians per language.
Accuracy: English WER with Whisper's English normaliser, Japanese and
Mandarin CER (basic normaliser, spaces removed), as streams/asr/scripts/score.py.
"""
import json
import os
import re
import statistics as st
import sys

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
refs = {}
for line in open(os.path.join(HERE, "work", "testset", "refs.tsv"), encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    refs[f[0]] = {"ref": f[2], "lang": f[3], "wake_end": float(f[4]), "c0": float(f[5]), "c1": float(f[6])}

log, per_utt = sys.argv[1], "--per-utt" in sys.argv
only = re.compile(sys.argv[sys.argv.index("--only") + 1]) if "--only" in sys.argv else None
utts = {}  # id -> utterance dict
seen = set()  # clips in the log
pending = []
clip = None
for line in open(log, encoding="utf-8", errors="replace"):
    m = re.search(r"utterance (\{.*\})\s*$", line)
    if m:
        u = json.loads(m.group(1))
        if clip:
            utts.setdefault(clip, u)
        else:
            pending.append(u)
        continue
    m = re.match(r"# clip (\S+)", line)
    if m:
        clip = m.group(1)
        seen.add(clip)
        continue
    if line.startswith('{"file":'):
        j = json.loads(line)
        cid = os.path.basename(j["file"])[:-4]
        seen.add(cid)
        if pending:
            utts[cid] = pending[0]
        pending = []

basic, eng = BasicTextNormalizer(), EnglishTextNormalizer()


def norm(lang, s):
    return eng(s) if lang == "en" else basic(s).replace(" ", "")


def med(v):
    v = [x for x in v if x is not None]
    return f"{st.median(v):.0f}" if v else "-"


print(f"{log}: {len(utts)} utterances")
rows = []
for lang in ("en", "ja", "zh"):
    ids = [i for i in refs if refs[i]["lang"] == lang and i in seen and (not only or only.fullmatch(i))]
    have = [i for i in ids if i in utts]
    r = [norm(lang, refs[i]["ref"]) for i in ids]
    h = [norm(lang, utts[i]["request"]) if i in utts else "" for i in ids]
    run = [(a, b) for a, b, i in zip(r, h, ids) if i in utts]
    if not ids or not run:
        continue
    ra, ha = zip(*run)
    rate = jiwer.wer(list(ra), list(ha)) if lang == "en" else jiwer.cer(list(ra), list(ha))
    U = [utts[i] for i in have]
    lag = [p["lag"] for u in U for p in u["phrases"] if "lag" in p]
    langok = sum(1 for u in U for p in u["phrases"] if p["lang"] == lang)
    nph = sum(len(u["phrases"]) for u in U)
    stream = sum(1 for u in U for p in u["phrases"] if p.get("streamed"))
    print(f"{lang}: {len(have)}/{len(ids)} woke; {'WER' if lang == 'en' else 'CER'} {rate * 100:.2f}% (over the woken ones);"
          f" phrases {nph} ({stream} streamed), language right {langok}/{nph}")
    print(f"   median ms: wake->captions {med([u['captions_ms'] for u in U])}, wake->first text {med([u['first_text_ms'] for u in U])},"
          f" caption lag {med(lag)}, end of speech->thinking {med([u['end_to_thinking_ms'] for u in U])},"
          f" enc {med([p['enc'] for u in U for p in u['phrases'] if 'enc' in p])}, dec {med([p['dec'] for u in U for p in u['phrases'] if 'dec' in p])},"
          f" cpu {st.median([u['cpu_s'] for u in U]):.1f} s, block max {max(u['block_max_ms'] for u in U):.1f} ms,"
          f" blocks >20ms {sum(u['blocks_over_20ms'] for u in U)}, xruns {sum(u['xruns'] for u in U)},"
          f" vad max {max(u.get('vad_ms_max', 0) for u in U):.1f} ms, rss peak {max(u.get('rss_peak_kib', 0) for u in U) // 1024} MiB")
    if per_utt:
        for i in ids:
            u = utts.get(i)
            if not u:
                print(f"   {i}: no wake")
                continue
            ph = " | ".join(f"{p['lang']}:{p['text']} (lag {p.get('lag')}, {'s' if p.get('streamed') else 'w'})" for p in u["phrases"])
            print(f"   {i}: cap {u['captions_ms']} first {u['first_text_ms']} e2t {u['end_to_thinking_ms']} :: {ph}")
            print(f"        ref: {refs[i]['ref']}")
