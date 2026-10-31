#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Summarise sla-file JSONL (phrase/sla-file.cpp, the recogniser of
straylight-listen over WAV files), with and without the prompt-prefix cache
and the header draft.

    sla-summary.py RESULTS.jsonl... [--per-phrase]

Utterances are grouped by set: the command clips (cmd-en/ja/zh, by the
directory of the WAV) and the phrase set (work/testset/phrase: en, ja, zh, mx,
lx-en/ja/zh by id). References come from each set's refs.tsv.

Per group and mode (off, prefix, draft, force; see sla-file.cpp): prefill = decoder prefill of each phrase (graph
build, compute, logits; ms, median over phrases), prompt = prompt tokens,
reused = tokens taken from the cache, draft = header tokens accepted of those
drafted; decode = the run's whole decoder time; lag = caption lag (VAD end of
the phrase's speech to its text, median over phrases); end = end of the last
speech to the final text (median over utterances); accuracy is corpus-level
(WER for English, CER with spaces removed otherwise, mixed utterances as CER).
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
TS = os.path.join(ROOT, "work", "testset")
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


def pf(s, k):
    m = re.search(rf"{k}=([\d.]+)(?:/(\d+))?", s or "")
    return (float(m.group(1)), int(m.group(2)) if m.group(2) else None) if m else (None, None)


def med(v):
    v = [x for x in v if x is not None]
    return st.median(v) if v else float("nan")


def main():
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    per_phrase = "--per-phrase" in sys.argv
    by = defaultdict(lambda: defaultdict(list))
    texts = defaultdict(dict)  # (cache, cid) -> text
    l0 = defaultdict(dict)  # cache -> (cid, phrase, T_prompt, context) -> max logit after the prompt (hex)
    order = []
    for fn in files:
        for line in open(fn, encoding="utf-8"):
            if not line.startswith("{"):
                continue
            u = json.loads(line)
            cid, g, lang = group(u["file"])
            c = u["cache"]
            if g not in order:
                order.append(g)
            b = by[(g, c)]
            b["lang"] = lang
            b["acc"].append((refs[cid], u["text"]))
            texts[c][cid] = u["text"]
            ph = u["phrases"]
            b["n_phrases"].append(len(ph))
            for p in ph:
                b["prefill"].append(pf(p["prefill"], "prefill_ms")[0])
                b["prompt"].append(pf(p["prefill"], "T_prompt")[0])
                b["reused"].append(pf(p["prefill"], "reused")[0])
                ok, n = pf(p["prefill"], "draft")
                b["draft_ok"].append(int(ok or 0))
                b["draft_n"].append(n or 0)
                b["decode"].append(p["dec"])
                b["lag"].append(p["t_done"] - p["t_speech_end"])
                b["streamed"].append(p["streamed"])
                m = re.search(r"T_prompt=(\d+).* l0=(\S+)", p["prefill"] or "")
                if m:
                    l0[c][(cid, p["i"], int(m.group(1)), p["ctx_bytes"])] = m.group(2)
                if per_phrase:
                    print(c, cid, p["i"], p["streamed"], round(p["t_done"] - p["t_speech_end"]), p["prefill"],
                          p["text"], sep="\t")
            if ph:
                b["end"].append(ph[-1]["t_done"] - ph[-1]["t_speech_end"])
            for s in u.get("begin", []):  # prompt prefix prefilled at stream begin
                m = re.search(r"(\d+) prefilled in ([\d.]+) ms", s)
                if m and int(m.group(1)) > 0:
                    b["begin_tok"].append(int(m.group(1)))
                    b["begin_ms"].append(float(m.group(2)))
    print("| set | cache | utts | phrases | prompt | reused | header draft | prefill | decode | caption lag | end of speech to text | accuracy |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    modes = [m for m in ("off", "prefix", "draft", "force") if any(k[1] == m for k in by)]
    for g in order:
        for c in modes:
            b = by.get((g, c))
            if not b:
                continue
            lang = b["lang"]
            acc = rate(b["acc"], lang)
            dn = sum(b["draft_n"])
            print(f"| {g} | {c} | {len(b['acc'])} | {sum(b['n_phrases'])} | "
                  f"{med(b['prompt']):.0f} | {med(b['reused']):.0f} | "
                  f"{(f'{sum(b['draft_ok'])}/{dn}' if dn else '-')} | {med(b['prefill']):.0f} ms | "
                  f"{med(b['decode']):.0f} ms | {med(b['lag']) / 1000:.2f} s | {med(b['end']) / 1000:.2f} s | "
                  f"{'WER' if lang == 'en' else 'CER'} {acc:.2f} % |")
    for g, c in ((g, c) for g in order for c in modes):
        b = by.get((g, c))
        if b and b["begin_ms"]:
            print(f"{g} {c}: prompt prefix prefilled at stream begin (during speech): {len(b['begin_ms'])} times, "
                  f"median {med(b['begin_tok']):.0f} tokens in {med(b['begin_ms']):.0f} ms")
    for c in modes[1:]:
        both = [cid for cid in texts[modes[0]] if cid in texts[c]]
        same = [cid for cid in both if texts[modes[0]][cid] == texts[c][cid]]
        keys = [k for k in l0[modes[0]] if k in l0[c]]
        same_l = [k for k in keys if l0[modes[0]][k] == l0[c][k]]
        print(f"\nphrases with the same prompt length and context in {modes[0]} and {c}: {len(keys)}, "
              f"bit-identical first-token logit: {len(same_l)}")
        print(f"identical text, {modes[0]} and {c}: {len(same)} of {len(both)} utterances")
        for cid in both:
            if texts[modes[0]][cid] != texts[c][cid]:
                print(f"  {cid}\n    {modes[0]}: {texts[modes[0]][cid]}\n    {c}: {texts[c][cid]}")


if __name__ == "__main__":
    main()
