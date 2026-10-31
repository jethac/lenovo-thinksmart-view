#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer>=3.0", "whisper-normalizer"]
# ///
"""Summarise phrase-stream JSONL against work/testset/phrase/{refs,parts}.tsv.

    phrase-summary.py RESULTS.jsonl [--endpoint-ms MS] [--per-utt]

Groups: en/ja/zh (joined command clips), mx (mixed languages), lx-en/ja/zh
(single long clips with natural pauses). Medians over utterances (caption lag:
over phrases). Accuracy is corpus-level: WER for English, CER (spaces removed)
for Japanese, Mandarin and mixed utterances; for mixed utterances the phrase
path is also scored per part (each phrase assigned to the part it overlaps
most), English parts as WER, the others as CER.

end-of-speech wait, phrase path: last text out - end of the last speech (offline
Silero, unpadded). Offline path: the endpoint silence it needs to start (same
as the phrase cut pause, --endpoint-ms) + whole-utterance transcription time.
"""
import json
import os
import statistics as st
import sys
from collections import defaultdict

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SET = os.path.join(ROOT, "work", "testset", "phrase")
EN, BASIC = EnglishTextNormalizer(), BasicTextNormalizer()


def norm(text, lang):
    return EN(text) if lang == "en" else BASIC(text).replace(" ", "")


class Acc:
    """Corpus-level error rate accumulator."""

    def __init__(self, lang):
        self.lang, self.err, self.n = lang, 0, 0

    def add(self, ref, hyp):
        r, h = norm(ref, self.lang), norm(hyp, self.lang)
        if not r:
            return
        if self.lang == "en":
            o = jiwer.process_words(r, h if h else "")
            self.err += o.substitutions + o.deletions + o.insertions
            self.n += len(r.split())
        else:
            o = jiwer.process_characters(r, h if h else "")
            self.err += o.substitutions + o.deletions + o.insertions
            self.n += len(r)

    def __str__(self):
        if not self.n:
            return "-"
        return f"{'WER' if self.lang == 'en' else 'CER'} {100 * self.err / max(self.n, 1):.2f} %"


def group(uid):
    if uid.startswith("lx-"):
        return uid[:5]
    return uid.split("-")[0]


def med(xs):
    return st.median(xs) if xs else float("nan")


def main():
    args = sys.argv[1:]
    endpoint = 300
    per_utt = "--per-utt" in args
    if "--endpoint-ms" in args:
        endpoint = int(args[args.index("--endpoint-ms") + 1])
    path = [a for a in args if a.endswith(".jsonl")][0]
    refs = {l.split("\t")[0]: l.rstrip("\n").split("\t")[2] for l in open(os.path.join(SET, "refs.tsv"), encoding="utf-8")}
    parts = defaultdict(list)
    for l in open(os.path.join(SET, "parts.tsv"), encoding="utf-8"):
        uid, k, lang, s, e, ref = l.rstrip("\n").split("\t")
        parts[uid].append((lang, float(s) * 1e3, float(e) * 1e3, ref))

    G = defaultdict(lambda: defaultdict(list))
    accs = {}
    for line in open(path, encoding="utf-8"):
        d = json.loads(line)
        uid = os.path.splitext(os.path.basename(d["wav"]))[0]
        g = group(uid)
        langs = {p[0] for p in parts[uid]}
        ulang = langs.pop() if len(langs) == 1 else "mx"
        alang = "ja" if ulang == "mx" else ulang  # CER for mixed
        a = accs.setdefault(g, {"phrase": Acc(alang), "offline": Acc(alang), "en_parts": Acc("en"), "cjk_parts": Acc("ja")})
        R = G[g]
        ph = d.get("phrases", [])
        if ph:
            a["phrase"].add(refs[uid], d["text"])
            R["n_phrases"].append(len(ph))
            R["phrase_len"] += [p["end"] - p["start"] for p in ph]
            R["lag"] += [p["t_done"] - p["speech_end"] for p in ph]
            R["first_lag"].append(ph[0]["t_done"] - ph[0]["speech_end"])
            R["queue"] += [p["t_start"] - p["t_cut"] for p in ph]
            R["queue_max"].append(max(p["t_start"] - p["t_cut"] for p in ph))
            R["wait"].append(ph[-1]["t_done"] - d["speech_end"])
            R["forced"].append(sum(p["forced"] for p in ph))
            R["busy"].append(d["asr_busy_ms"] / max(d["speech_end"] - d["speech_start"], 1))
            R["cpu"].append(d["cpu_feed_ms"] / d["feed_end"] / 8)
            R["late"].append(d["feed_late_max"])
            R["audio"].append(d["audio_ms"])
            R["ctx"] += [p["ctx_bytes"] for p in ph]
            # phrase -> part with most overlap
            per = defaultdict(str)
            for p in ph:
                ov = [max(0, min(p["end"], e) - max(p["start"], s)) for _, s, e, _ in parts[uid]]
                k = max(range(len(ov)), key=ov.__getitem__)
                if p["text"]:
                    sep = " " if per[k] and per[k][-1].isascii() and p["text"][0].isascii() else ""
                    per[k] += sep + p["text"]
                    R["lang_ok"].append(p["lang"] == parts[uid][k][0])
                    if p["lang"] != parts[uid][k][0]:
                        R["lang_bad"].append(f"{uid}#{k}:{parts[uid][k][0]}->{p['lang'] or '?'}")
            if ulang == "mx":
                for k, (lang, _, _, ref) in enumerate(parts[uid]):
                    a["en_parts" if lang == "en" else "cjk_parts"].add(ref, per[k])
            R["spans"].append(sum(1 for p in ph if sum(1 for _, s, e, _ in parts[uid] if min(p["end"], e) - max(p["start"], s) > 200) > 1))
        if "offline" in d:
            o = d["offline"]
            a["offline"].add(refs[uid], o["text"])
            R["off_wall"].append(o["wall"])
            R["off_wait"].append(o["wall"] + endpoint)
            R["off_lang"].append(o["lang"])
        R["rss"].append(d["peak_rss_kib"] / 1024)
        if per_utt:
            print(uid, f"{d['audio_ms'] / 1e3:.1f}s", len(ph), "phrases",
                  f"wait {ph[-1]['t_done'] - d['speech_end']:.0f}" if ph else "",
                  f"off {d['offline']['wall']:.0f}" if "offline" in d else "")
            for p in ph:
                print(f"   {p['start']:6.0f}-{p['end']:6.0f} lag {p['t_done'] - p['speech_end']:5.0f} q {p['t_start'] - p['t_cut']:5.0f} "
                      f"{p['lang']:3s} {p['text']}")
            if "offline" in d:
                print(f"   offline {d['offline']['lang']}: {d['offline']['text']}")
            print(f"   ref: {refs[uid]}")

    order = [g for g in ("en", "ja", "zh", "mx", "lx-en", "lx-ja", "lx-zh") if g in G]
    print("| Group | Utts | Audio | Phrases | Phrase len | Caption lag | First lag | Max queue | End wait | Offline wait | ASR busy | CPU | Phrase acc | Offline acc | Peak RSS |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for g in order:
        R, a = G[g], accs[g]
        print(f"| {g} | {len(R['rss'])} | {med(R['audio']) / 1e3:.1f} s | {med(R['n_phrases']):.0f} | {med(R['phrase_len']) / 1e3:.1f} s "
              f"| {med(R['lag']) / 1e3:.2f} s | {med(R['first_lag']) / 1e3:.2f} s | {med(R['queue_max']) / 1e3:.2f} s "
              f"| {med(R['wait']) / 1e3:.2f} s | {med(R['off_wait']) / 1e3:.2f} s | {med(R['busy']):.2f} | {100 * med(R['cpu']):.0f} % "
              f"| {a['phrase']} | {a['offline']} | {max(R['rss']):.0f} MiB |")
    print()
    for g in order:
        R, a = G[g], accs[g]
        extra = f"; parts: en {a['en_parts']}, ja/zh {a['cjk_parts']}" if g == "mx" else ""
        print(f"{g}: lang ok {sum(R['lang_ok'])}/{len(R['lang_ok'])} {' '.join(R['lang_bad'])}; offline lang {R['off_lang']}; "
              f"forced splits {sum(R['forced'])}; phrases over 2 parts {sum(R['spans'])}; lag p90 "
              f"{sorted(R['lag'])[int(0.9 * (len(R['lag']) - 1))] / 1e3 if R['lag'] else float('nan'):.2f} s; "
              f"max feed late {max(R['late']) if R['late'] else 0:.0f} ms; ctx median {med(R['ctx']):.0f} B{extra}")


if __name__ == "__main__":
    main()
