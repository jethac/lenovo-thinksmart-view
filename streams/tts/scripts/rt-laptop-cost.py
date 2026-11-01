#!/usr/bin/env python3
"""Relative cost of the TTS candidates on the laptop: one thread, the same
English 3-sentence reply (cases/rt-lines.tsv en-3), seconds of compute per
second of audio. Ranks them before device runs; espeak-ng phonemes (laptop
only) for the phoneme-input models.

    rt-laptop-cost.py SHERPA_MODELS_DIR KOKORO_ONNX [THREADS]
"""
import sys, time
import numpy as np
import sherpa_onnx as s
import espeakng_loader as e
from phonemizer.backend.espeak.wrapper import EspeakWrapper

EspeakWrapper.set_library(e.get_library_path())
EspeakWrapper.set_data_path(e.get_data_path())
from phonemizer.backend import EspeakBackend

d, kokoro = sys.argv[1], sys.argv[2]
th = int(sys.argv[3]) if len(sys.argv) > 3 else 1
txt = "Good morning. You have three meetings today, and the first one starts at nine thirty. The afternoon is free after two, so it's a good time for focused work."
ph = EspeakBackend("en-us", preserve_punctuation=True, with_stress=True).phonemize([txt])[0].strip()


def run(name, mc, gen=None, text=txt, reps=2):
    mc.num_threads = th
    t = s.OfflineTts(s.OfflineTtsConfig(model=mc, max_num_sentences=10))
    g = gen or s.GenerationConfig()
    t.generate(text, g)
    best = 1e9
    for _ in range(reps):
        t0 = time.time()
        a = t.generate(text, g)
        best = min(best, time.time() - t0)
    dur = len(a.samples) / a.sample_rate
    print(f"{name}\taudio {dur:.2f} s\tsynth {best:.2f} s\tRTF {best / dur:.3f}\t{a.sample_rate} Hz", flush=True)


def phon():
    g = s.GenerationConfig()
    g.phoneme_codepoints = [[ord(c) for c in ph]]
    return g


m = f"{d}/vits-piper-en_US-kristin-medium/"
run("piper-kristin-medium", s.OfflineTtsModelConfig(vits=s.OfflineTtsVitsModelConfig(model=m + "en_US-kristin-medium.onnx", tokens=m + "tokens.txt")), phon())
m = f"{d}/vits-piper-en_US-ljspeech-medium/"
run("piper-ljspeech-medium", s.OfflineTtsModelConfig(vits=s.OfflineTtsVitsModelConfig(model=m + "en_US-ljspeech-medium.onnx", tokens=m + "tokens.txt")), phon())
m = f"{d}/matcha-icefall-en_US-ljspeech/"
run("matcha-ljspeech-3steps+vocos", s.OfflineTtsModelConfig(matcha=s.OfflineTtsMatchaModelConfig(acoustic_model=m + "model-steps-3.onnx", vocoder=f"{d}/vocos-22khz-univ.onnx", tokens=m + "tokens.txt")), phon())
for k in ("kitten-nano-en-v0_8-int8", "kitten-mini-en-v0_8"):
    m = f"{d}/{k}/"
    run(k, s.OfflineTtsModelConfig(kitten=s.OfflineTtsKittenModelConfig(model=m + ("model.int8.onnx" if "int8" in k else "model.onnx"), voices=m + "voices.bin", tokens=m + "tokens.txt")), phon())
m = f"{d}/sherpa-onnx-supertonic-3-tts-int8-2026-05-11/"
for steps in (5, 3):
    g = s.GenerationConfig()
    g.sid, g.num_steps = 6, steps
    run(f"supertonic3-int8-{steps}steps", s.OfflineTtsModelConfig(supertonic=s.OfflineTtsSupertonicModelConfig(m + "duration_predictor.int8.onnx", m + "text_encoder.int8.onnx", m + "vector_estimator.int8.onnx", m + "vocoder.int8.onnx", m + "tts.json", m + "unicode_indexer.bin", m + "voice.bin")), g)
m = f"{d}/vits-melo-tts-zh_en/"
run("melo-zh_en (en text)", s.OfflineTtsModelConfig(vits=s.OfflineTtsVitsModelConfig(model=m + "model.onnx", lexicon=m + "lexicon.txt", tokens=m + "tokens.txt", dict_dir=m + "dict")))
m = f"{d}/vits-icefall-zh-aishell3/"
run("vits-icefall-aishell3 (zh text)", s.OfflineTtsModelConfig(vits=s.OfflineTtsVitsModelConfig(model=m + "model.onnx", lexicon=m + "lexicon.txt", tokens=m + "tokens.txt")),
    text="早上好。你今天有三个会议，第一个九点半开始。下午两点以后没有安排，适合专心工作。")

# Kokoro uint8 via onnxruntime directly is not in this venv; the reference
# point is the known device RTF 2.94 for it.
