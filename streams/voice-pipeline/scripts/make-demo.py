#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["soundfile", "numpy"]
# ///
"""Pad the synthesised demo requests (work/demo/demo-<lang>.wav, Magpie TTS
speaker 4: "Hey Straylight, what's the weather tomorrow?" and the same in
Japanese and Mandarin) like the test set: 2 s of room noise first (the
detector's warm-up), speech at -22 dBFS, 2.5 s of noise after; 16 kHz mono
and 48 kHz stereo into work/testset/{16k,48k}/demo-<lang>.wav."""
import importlib.util, os, sys
import numpy as np, soundfile as sf
HERE = os.path.dirname(os.path.abspath(__file__))

src = open(os.path.join(HERE, "make-testset.py")).read().replace("\nmain()\n", "\n")
mt = {"__file__": os.path.join(HERE, "make-testset.py")}
exec(compile(src, "make-testset.py", "exec"), mt)
for lang in ("en", "ja", "zh"):
    a = mt["level"](mt["trim"](mt["load"](os.path.join(mt["HERE"], "work", "demo", f"demo-{lang}.wav")), 0.05))
    a = np.clip(np.concatenate([mt["noise"](2 * 16000), a, mt["noise"](int(2.5 * 16000))]), -1, 1)
    sf.write(os.path.join(mt["OUT"], "16k", f"demo-{lang}.wav"), a, 16000, subtype="PCM_16")
    s = np.clip(mt["resample48"](a), -1, 1)
    sf.write(os.path.join(mt["OUT"], "48k", f"demo-{lang}.wav"), np.stack([s, s], 1), 48000, subtype="PCM_16")
    print(lang, len(a) / 16000)
