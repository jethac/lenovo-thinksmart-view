#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Build the ASR test set from LibriSpeech test-clean and FLEURS ja_jp test.

    prep-testset.py LIBRISPEECH_DIR FLEURS_JA_DIR OUT_DIR

LIBRISPEECH_DIR contains LibriSpeech/test-clean; FLEURS_JA_DIR contains
test.tsv and test/*.wav. Writes 16 kHz mono 16-bit WAV files and, per set,
a refs.tsv with "id<TAB>wav<TAB>reference":

    en-wer/  100 random test-clean utterances (seed 0)
    ja-cer/  100 random FLEURS ja test utterances (seed 0)
    clips/   en-5s, en-15s, en-60s, ja-5s, ja-15s, ja-60s (60 s = consecutive
             utterances concatenated with 0.3 s of silence between them)
"""
import random
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 16000


def write(path, audio):
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, audio, SR, subtype="PCM_16")


def load(path):
    a, sr = sf.read(path, dtype="float32", always_2d=True)
    assert sr == SR, (path, sr)
    return a.mean(axis=1)


def librispeech(root):
    utts = []
    for trans in sorted((root / "LibriSpeech" / "test-clean").glob("*/*/*.trans.txt")):
        for line in trans.read_text().splitlines():
            uid, text = line.split(" ", 1)
            utts.append((uid, trans.parent / f"{uid}.flac", text))
    return utts


def fleurs(root):
    utts, seen = [], set()
    for line in (root / "test.tsv").read_text().splitlines():
        f = line.split("\t")
        wav = root / "test" / f[1]
        if f[1] in seen or not wav.exists():
            continue
        seen.add(f[1])
        utts.append((f[1].removesuffix(".wav"), wav, f[2]))
    return utts


def closest(utts, dur, secs):
    return min(utts, key=lambda u: abs(dur[u[0]] - secs))


def concat(utts, start, secs, sep):
    parts, texts, total = [], [], 0.0
    gap = np.zeros(int(0.3 * SR), dtype=np.float32)
    for uid, path, text in utts[start:]:
        a = load(path)
        if total + len(a) / SR > secs + 2:
            continue
        parts += [a, gap]
        texts.append(text)
        total += len(a) / SR + 0.3
        if total >= secs - 2:
            break
    return np.concatenate(parts[:-1]), sep.join(texts)


def main():
    ls_dir, fl_dir, out = (Path(p) for p in sys.argv[1:4])
    sets = {"en": librispeech(ls_dir), "ja": fleurs(fl_dir)}
    clips = []
    for lang, utts in sets.items():
        dur = {u[0]: sf.info(u[1]).duration for u in utts}
        rng = random.Random(0)
        pick = rng.sample(utts, 100)
        name = "en-wer" if lang == "en" else "ja-cer"
        rows = []
        for uid, path, text in pick:
            dst = out / name / f"{uid}.wav"
            write(dst, load(path))
            rows.append(f"{uid}\t{dst}\t{text}")
        (out / name / "refs.tsv").write_text("\n".join(rows) + "\n")
        for secs in (5, 15):
            uid, path, text = closest(utts, dur, secs)
            dst = out / "clips" / f"{lang}-{secs}s.wav"
            write(dst, load(path))
            clips.append(f"{lang}-{secs}s\t{dst}\t{text}")
        a, text = concat(utts, 0, 60, " " if lang == "en" else "")
        dst = out / "clips" / f"{lang}-60s.wav"
        write(dst, a)
        clips.append(f"{lang}-60s\t{dst}\t{text}")
    (out / "clips" / "refs.tsv").write_text("\n".join(clips) + "\n")
    for line in clips:
        cid, wav, _ = line.split("\t")
        print(cid, f"{sf.info(wav).duration:.2f} s")


if __name__ == "__main__":
    main()
