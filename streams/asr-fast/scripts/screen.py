#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["sherpa-onnx>=1.12.28", "numpy", "soundfile"]
# ///
"""Laptop accuracy screen of sherpa-onnx models over the ASR test sets.

    screen.py KIND MODEL_DIR OUT_DIR [--threads N] [--hotwords FILE]

KIND: sensevoice, moonshine2, online-transducer, offline-transducer.
Writes OUT_DIR/<set>.tsv (id<TAB>text, plus <set>.lang.tsv for SenseVoice's
detected language) for the command sets (cmd-en/ja/zh) and the phrase set,
each clip decoded whole; scripts/score.py scores them. Timing on the laptop
is not meaningful.
"""
import argparse
import glob
import os
import time

import numpy as np
import sherpa_onnx
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = os.path.join(ROOT, "..", "asr", "work", "testset")
SETS = ["cmd-en", "cmd-ja", "cmd-zh", "phrase"]


def one(d, pat):
    m = sorted(x for x in glob.glob(os.path.join(d, pat)) if x.endswith((".onnx", ".ort")))
    if not m:
        raise SystemExit(f"no {pat} in {d}")
    # Prefer int8 files where both exist.
    i8 = [x for x in m if "int8" in os.path.basename(x)]
    return (i8 or m)[0]


def build(kind, d, threads, hotwords):
    tokens = os.path.join(d, "tokens.txt")
    if kind == "sensevoice":
        return "offline", sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=one(d, "model*"), tokens=tokens, num_threads=threads, use_itn=True, language="auto")
    if kind == "moonshine2":
        return "offline", sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
            encoder=one(d, "encoder*"), decoder=one(d, "*decoder*"), tokens=tokens,
            num_threads=threads)
    if kind == "offline-transducer":
        return "offline", sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=one(d, "encoder*"), decoder=one(d, "decoder*"), joiner=one(d, "joiner*"),
            tokens=tokens, num_threads=threads)
    if kind == "online-transducer":
        kw = {}
        if hotwords:
            kw = dict(decoding_method="modified_beam_search", hotwords_file=hotwords, hotwords_score=1.5)
        return "online", sherpa_onnx.OnlineRecognizer.from_transducer(
            encoder=one(d, "encoder*"), decoder=one(d, "decoder*"), joiner=one(d, "joiner*"),
            tokens=tokens, num_threads=threads, **kw)
    raise SystemExit(f"unknown kind {kind}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind")
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--hotwords")
    a = ap.parse_args()
    mode, rec = build(a.kind, a.model_dir, a.threads, a.hotwords)
    os.makedirs(a.out_dir, exist_ok=True)
    for s in SETS:
        refs = [l.rstrip("\n").split("\t") for l in open(os.path.join(TS, s, "refs.tsv"), encoding="utf-8")]
        t0 = time.time()
        with open(os.path.join(a.out_dir, f"{s}.tsv"), "w", encoding="utf-8") as fo, \
                open(os.path.join(a.out_dir, f"{s}.lang.tsv"), "w", encoding="utf-8") as fl:
            for cid, wav, _ in refs:
                x, sr = sf.read(wav, dtype="float32")
                if mode == "offline":
                    st = rec.create_stream()
                    st.accept_waveform(sr, x)
                    rec.decode_stream(st)
                    r = st.result
                    text, lang = r.text, getattr(r, "lang", "")
                else:
                    st = rec.create_stream()
                    st.accept_waveform(sr, x)
                    st.accept_waveform(sr, np.zeros(int(sr * 2.0), dtype=np.float32))
                    st.input_finished()
                    while rec.is_ready(st):
                        rec.decode_stream(st)
                    text, lang = rec.get_result(st), ""
                text = text.replace("\t", " ").replace("\n", " ").strip()
                fo.write(f"{cid}\t{text}\n")
                fl.write(f"{cid}\t{lang}\n")
        print(f"{s}: {len(refs)} clips in {time.time() - t0:.1f} s", flush=True)


if __name__ == "__main__":
    main()
