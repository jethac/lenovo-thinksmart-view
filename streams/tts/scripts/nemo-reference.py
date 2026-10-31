"""Synthesise the listening lines with the NeMo reference implementation.

    nemo-reference.py MODEL.nemo LINES.tsv OUTDIR [--speakers 0,1,2,3,4] [--seed 1]

Writes OUTDIR/<speaker>-<id>.wav (22.05 kHz, 16-bit) and OUTDIR/timing.tsv.
Runs on CUDA when available. Text normalisation is off (the lines are already
in spoken form), CFG on, the model's default sampling settings.
"""
import argparse, json, os, time, wave

import numpy as np
import torch
from nemo.collections.tts.models import MagpieTTSModel

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("lines"); ap.add_argument("out")
ap.add_argument("--speakers", default="0,1,2,3,4"); ap.add_argument("--seed", type=int, default=1)
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
dev = "cuda" if torch.cuda.is_available() else "cpu"
model = MagpieTTSModel.restore_from(a.model, map_location="cpu").eval()
# Inference only: the decoder KV cache (as in the C++ runtime) and no modules
# that synthesis does not use, so it fits a 4 GB GPU.
model.use_kv_cache_for_inference = True
for name in ("_speaker_verification_model",):
    if hasattr(model, name):
        delattr(model, name)
codec = model._codec_model
for name in ("audio_encoder", "discriminator", "speaker_encoder"):
    if hasattr(codec, name):
        setattr(codec, name, None)
model = model.to(dev)
names = {v: k for k, v in json.load(open(
    [os.path.join(dp, f) for dp, _, fs in os.walk(os.path.dirname(a.model)) for f in fs if f.endswith("speakers.json")][0])).items()}
lines = [l.rstrip("\n").split("|", 2) for l in open(a.lines, encoding="utf-8") if l.strip() and not l.startswith("#")]
with open(os.path.join(a.out, "timing.tsv"), "w") as tf:
    tf.write("file\tseconds_audio\tseconds_wall\n")
    for spk in map(int, a.speakers.split(",")):
        for lid, lang, text in lines:
            torch.manual_seed(a.seed)
            t0 = time.time()
            with torch.inference_mode():
                audio, alen = model.do_tts(text, language=lang, apply_TN=False, speaker_index=spk)
            if dev == "cuda": torch.cuda.synchronize()
            wall = time.time() - t0
            x = audio[0, : int(alen[0])].float().cpu().numpy()
            pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
            fn = f"{names[spk].lower()}-{lid}.wav"
            with wave.open(os.path.join(a.out, fn), "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050); w.writeframes(pcm.tobytes())
            tf.write(f"{fn}\t{len(pcm)/22050:.2f}\t{wall:.2f}\n"); tf.flush()
            print(fn, f"{len(pcm)/22050:.2f}s", f"{wall:.2f}s", flush=True)
