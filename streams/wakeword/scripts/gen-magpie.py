"""Synthetic clips from Magpie TTS (laptop build of NeMo-Speech.cpp, see ../tts).

    gen-magpie.py OUTDIR {pos|neg} {train|test} [WORKERS]

Speakers 0-3 (Aria, Jason, John, Leo) are used for training; speaker 4
(Sofia) only for test, plus a few unseen seeds of the others. English text
in ja/zh mode, or the phrase in katakana or hanzi, gives Japanese- and
Mandarin-accented renderings. Sampling temperature varies per clip.
Output: 16 kHz mono WAVs and texts.tsv.
"""
import os
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from phrases import NEG_MAGPIE, POS_MAGPIE  # noqa: E402

TTS = Path(__file__).resolve().parents[2] / "tts"
M = TTS / "downloads/models"
B = TTS / "work/build-native"
ENV = dict(os.environ, MAGPIE_OPENJTALK_DIC_DIR=str(B / "open_jtalk_dic"),
           MAGPIE_MANDARIN_G2P_DIR=str(TTS / "downloads/NeMo-Speech.cpp/src/tts/tokenizer/mandarin_data"))


def jobs(kind, split):
    items = POS_MAGPIE if kind == "pos" else NEG_MAGPIE
    out = []
    if split == "train":
        seeds = range(1, 27) if kind == "pos" else range(1, 4)
        for spk in range(4):
            for s in seeds:
                for k, (lang, text) in enumerate(items):
                    out.append((spk, s, k, lang, text))
    else:
        seeds = range(1, 26) if kind == "pos" else range(1, 5)
        for s in seeds:
            for k, (lang, text) in enumerate(items):
                out.append((4, s, k, lang, text))
        if kind == "pos":
            for spk in range(4):
                for s in range(1000, 1003):
                    for k, (lang, text) in enumerate(items):
                        out.append((spk, s, k, lang, text))
    return out


def run(out, job):
    spk, seed, k, lang, text = job
    name = f"s{spk}-k{k}-{lang}-{seed}.wav"
    f = out / name
    temp = random.Random(hash((spk, seed, k))).choice([0.55, 0.65, 0.75, 0.85])
    if not f.exists():
        r = subprocess.run(
            [str(B / "bin/nemo-speech"), "synthesize", text,
             "--magpie-model", str(M / "magpie_tts_multilingual_357m.v2607.q8_0.gguf"),
             "--codec-model", str(M / "nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf"),
             "--tokenizer-dir", str(M / "magpie-tok"), "--language", lang, "--speaker", str(spk),
             "--seed", str(seed), "--temperature", str(temp), "--sample-rate", "16000",
             "--device", "cpu", "--tts.threads", "2", "--tts.chunk-frames", "1000", "--no-warmup",
             "-o", str(f), "--force"],
            env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            return f"{name}\tFAIL\t{r.stderr[-200:]!r}"
    return f"{name}\t{lang}\t{text}\t{spk}\t{seed}\t{temp}"


def main():
    out, kind, split = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    workers = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    out.mkdir(parents=True, exist_ok=True)
    js = jobs(kind, split)
    with ThreadPoolExecutor(workers) as ex, open(out / "texts.tsv", "w") as tsv:
        for i, line in enumerate(ex.map(lambda j: run(out, j), js)):
            tsv.write(line + "\n")
            if i % 200 == 0:
                print(f"{i}/{len(js)}", flush=True)
                tsv.flush()


if __name__ == "__main__":
    main()
