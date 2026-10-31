"""Synthetic clips from the Piper LibriTTS-R generator (904 speakers, mixed by SLERP).

    gen-piper.py OUTDIR {pos|neg} N SEED {train|test}

Each clip mixes two random speakers: training uses speakers 0-799, test uses
800-903 only, so test voices are never seen in training. Text, speed and
noise parameters are drawn per batch of 50. Clips are 22.05 kHz mono WAVs,
<seed>-<i>.wav, with texts.tsv listing what each one says.
"""
import json
import random
import sys
import wave
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from phrases import NEG_EN, POS_EN  # noqa: E402

from piper_sample_generator.__main__ import audio_float_to_int16, generate_audio, get_phonemes  # noqa: E402

D = Path(__file__).resolve().parent.parent / "downloads"
MODEL = D / "models/en_US-libritts_r-medium.pt"


def main():
    out, kind, n, seed, split = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    out.mkdir(parents=True, exist_ok=True)
    texts = POS_EN if kind == "pos" else NEG_EN
    spk = range(0, 800) if split == "train" else range(800, 904)
    rng = random.Random(seed)
    torch.manual_seed(seed)
    model = torch.load(MODEL, weights_only=False).eval().cuda()
    config = json.load(open(f"{MODEL}.json"))
    voice, sr = config["espeak"]["voice"], config["audio"]["sample_rate"]
    tsv = open(out / "texts.tsv", "a")
    batch = 50
    for b in range(0, n, batch):
        names = [f"{seed}-{i}.wav" for i in range(b, min(n, b + batch))]
        txt = [rng.choice(texts) for _ in names]
        s1 = torch.LongTensor([rng.choice(spk) for _ in names])
        s2 = torch.LongTensor([rng.choice(spk) for _ in names])
        ids = [get_phonemes(voice, config, t, False, False) for t in txt]
        m = max(len(x) for x in ids)
        ids = [x + [1] * (m - len(x)) for x in ids]
        with torch.no_grad():
            audio, ph = generate_audio(
                model, s1, s2, ids,
                rng.choice([0.2, 0.35, 0.5, 0.65, 0.8]),
                rng.choice([0.5, 0.667, 0.8, 0.95]),
                rng.choice([0.6, 0.8, 1.0]),
                rng.choice([0.75, 0.85, 0.95, 1.0, 1.1, 1.2, 1.3]),
                None,
            )
        for i in range(audio.shape[0]):
            audio[i, 0, int(ph[i].flatten().sum().item()) + 1:] = 0
        a16 = audio_float_to_int16(audio.cpu().numpy())
        for i, name in enumerate(names):
            with wave.open(str(out / name), "wb") as w:
                w.setframerate(sr)
                w.setsampwidth(2)
                w.setnchannels(1)
                w.writeframes(np.trim_zeros(a16[i].flatten()).tobytes())
            tsv.write(f"{name}\t{txt[i]}\t{int(s1[i])}\t{int(s2[i])}\n")
        tsv.flush()


if __name__ == "__main__":
    main()
