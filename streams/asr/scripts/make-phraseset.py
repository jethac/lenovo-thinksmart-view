#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Multi-phrase test utterances for phrase-by-phrase transcription, in
work/testset/phrase/.

    make-phraseset.py

- en-*, ja-*, zh-*: 2-4 clips of one language from the command sets
  (work/testset/cmd-*), edges trimmed to speech, joined with 300-700 ms gaps of
  low-level noise (not digital silence).
- mx-*: the same, mixing languages (code-switching between utterance parts).
- lx-*: single long clips (12-20 s) with their natural pauses: LibriSpeech
  test-clean (en), FLEURS test (ja, zh), not in the command sets.

Each clip is brought to a speech level of -22 dBFS first. Every utterance starts with 300 ms and ends with 1200 ms of the same noise.
refs.tsv: id<TAB>wav<TAB>reference (score.py format; parts joined with a space
only between two Latin-script parts). parts.tsv: id<TAB>part<TAB>lang<TAB>
start_s<TAB>end_s<TAB>reference, positions in the utterance.
"""
import csv
import os
import random

import numpy as np
import soundfile as sf

SR = 16000
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "work", "testset")
OUT = os.path.join(TS, "phrase")
DL = os.path.join(ROOT, "downloads", "audio")
rng = np.random.default_rng(0)
NOISE_RMS = 0.002  # about -54 dBFS


def noise(n):
    # Brown-ish room noise: integrated white noise, leaky, scaled to NOISE_RMS.
    w = rng.standard_normal(n + 2000)
    y = np.empty_like(w)
    acc = 0.0
    for i, v in enumerate(w):
        acc = 0.97 * acc + v
        y[i] = acc
    y = y[2000:]
    y -= y.mean()
    return (y / (np.sqrt((y ** 2).mean()) + 1e-12) * NOISE_RMS).astype(np.float32)


def load(path):
    a, sr = sf.read(path, dtype="float32", always_2d=True)
    assert sr == SR, (path, sr)
    return a.mean(axis=1)


def trim(a, margin_s=0.15):
    # Trim leading/trailing non-speech: 20 ms frames more than 35 dB below the loudest.
    f = 320
    n = len(a) // f
    rms = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1)) + 1e-9
    on = np.nonzero(20 * np.log10(rms / rms.max()) > -35)[0]
    s = max(0, on[0] * f - int(margin_s * SR))
    e = min(len(a), (on[-1] + 1) * f + int(margin_s * SR))
    return a[s:e]


def level(a, target_db=-22.0):
    # Bring speech to a common level (90th percentile of 20 ms frame RMS at
    # target_db), as a microphone AGC would; some FLEURS clips sit near -55 dBFS.
    f = 320
    n = len(a) // f
    rms = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1))
    g = 10 ** ((target_db - 20 * np.log10(np.percentile(rms, 90) + 1e-9)) / 20)
    g = min(g, 0.95 / (np.abs(a).max() + 1e-9))
    return (a * g).astype(np.float32)


def read_refs(name):
    rows = []
    for line in open(os.path.join(TS, name, "refs.tsv"), encoding="utf-8"):
        cid, wav, ref = line.rstrip("\n").split("\t", 2)
        rows.append((cid, wav, ref))
    return rows


def join_refs(parts):
    out = ""
    for lang, ref in parts:
        if out and (lang == "en" or out[-1].isascii()):
            out += " "
        out += ref
    return out


refs_f = parts_f = None


def emit(uid, items, natural=False):
    """items: list of (lang, wav, ref)."""
    audio = [noise(int(0.3 * SR))]
    pos = len(audio[0])
    parts = []
    for k, (lang, wav, ref) in enumerate(items):
        a = level(load(wav) if natural else trim(load(wav)))
        if k:
            g = noise(int(rng.uniform(0.3, 0.7) * SR))
            audio.append(g)
            pos += len(g)
        parts.append((k, lang, pos / SR, (pos + len(a)) / SR, ref))
        audio.append(a)
        pos += len(a)
    audio.append(noise(int(1.2 * SR)))
    a = np.clip(np.concatenate(audio), -1, 1)
    path = os.path.join(OUT, uid + ".wav")
    sf.write(path, a, SR, subtype="PCM_16")
    refs_f.write(f"{uid}\t{path}\t{join_refs([(p[1], p[4]) for p in parts])}\n")
    for k, lang, s, e, ref in parts:
        parts_f.write(f"{uid}\t{k}\t{lang}\t{s:.3f}\t{e:.3f}\t{ref}\n")
    print(f"{uid}: {len(a) / SR:.1f} s, {len(items)} part(s)")


def main():
    global refs_f, parts_f
    os.makedirs(OUT, exist_ok=True)
    refs_f = open(os.path.join(OUT, "refs.tsv"), "w", encoding="utf-8")
    parts_f = open(os.path.join(OUT, "parts.tsv"), "w", encoding="utf-8")
    cmd = {l: [(l, w, r) for _, w, r in read_refs(f"cmd-{l}")] for l in ("en", "ja", "zh")}
    for l in cmd:
        random.Random(l).shuffle(cmd[l])

    # One language: en 3-4 clips (8-11 s), ja 2 clips (14-15 s), zh 3 clips (14 s).
    groups = {"en": [3, 4, 4, 4], "ja": [2] * 7, "zh": [3] * 5}
    for l, sizes in groups.items():
        i = 0
        for u, n in enumerate(sizes):
            emit(f"{l}-{u + 1}", cmd[l][i:i + n])
            i += n

    # Code-switching: parts in different languages.
    pick = {l: iter(random.Random(f"mx-{l}").sample(cmd[l], len(cmd[l]))) for l in cmd}
    for u, pattern in enumerate(["en ja", "ja en", "en zh", "zh en", "en ja en", "zh ja", "ja zh", "en zh en"]):
        emit(f"mx-{u + 1}", [next(pick[l]) for l in pattern.split()])

    # Long single clips with natural pauses.
    used = {w for l in cmd for _, w, _ in cmd[l]}
    used_ids = {os.path.splitext(os.path.basename(w))[0] for w in used}
    ls = os.path.join(DL, "librispeech", "LibriSpeech", "test-clean")
    en_long = []
    for spk in sorted(os.listdir(ls)):
        for ch in sorted(os.listdir(os.path.join(ls, spk))):
            d = os.path.join(ls, spk, ch)
            for line in open(os.path.join(d, f"{spk}-{ch}.trans.txt")):
                cid, txt = line.rstrip("\n").split(" ", 1)
                f = os.path.join(d, cid + ".flac")
                if cid not in used_ids and 12 <= sf.info(f).frames / SR <= 18:
                    en_long.append(("en", f, txt))
    longs = {"en": random.Random(1).sample(en_long, 3)}
    for l, sub in (("ja", "fleurs-ja"), ("zh", "fleurs-zh")):
        base, seen, items = os.path.join(DL, sub), set(), []
        for row in csv.reader(open(os.path.join(base, "test.tsv"), encoding="utf-8"), delimiter="\t",
                              quoting=csv.QUOTE_NONE):
            f = os.path.join(base, "test", row[1])
            if row[1] in seen or not os.path.exists(f) or f"{l}-{os.path.splitext(row[1])[0]}" in used_ids:
                continue
            seen.add(row[1])
            if 12 <= sf.info(f).frames / SR <= 18:
                items.append((l, f, row[2]))
        longs[l] = random.Random(1).sample(sorted(items), 3)
    for l in ("en", "ja", "zh"):
        for u, it in enumerate(longs[l]):
            emit(f"lx-{l}-{u + 1}", [it], natural=True)


if __name__ == "__main__":
    main()
