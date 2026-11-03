#!/usr/bin/env python3
"""Render lines with an exported voice (model.onnx, vocos.onnx, tokens.txt)
through ONNX Runtime on the CPU, the way straylight-listen's Matcha engine
does (listen/src/tts/matcha.rs): input [_ ^ _ p1 _ ... pn _ $ _] with
symbols outside tokens.txt dropped, noise scale 0.667, then Vocos and an
inverse STFT (n_fft 1024, hop 256, Hann, centred).

    synth-onnx.py VOICE_DIR PHON.tsv OUT_DIR [--threads N] [--lang L]

PHON.tsv: id, lang, phonemes[, ms] (`straylight-listen --g2p` output).
Writes OUT_DIR/<id>.wav (22.05 kHz, PCM 16) and prints per-line timings.
"""
import argparse, os, time
import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("voice")
    ap.add_argument("phon")
    ap.add_argument("out")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--lang")
    ap.add_argument("--noise", type=float, default=0.667)
    ap.add_argument("--length", type=float, default=1.0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    ids = {}
    for l in open(os.path.join(a.voice, "tokens.txt"), encoding="utf-8"):
        l = l.rstrip("\n")
        s, _, i = l.rpartition(" ")
        if i.strip().lstrip("-").isdigit():
            ids[s if s else " "] = int(i)
    so = ort.SessionOptions()
    so.intra_op_num_threads = a.threads
    am = ort.InferenceSession(os.path.join(a.voice, "model.onnx"), so, providers=["CPUExecutionProvider"])
    vo = ort.InferenceSession(os.path.join(a.voice, "vocos.onnx"), so, providers=["CPUExecutionProvider"])
    win = torch.hann_window(1024)
    tot_a = tot_t = 0.0
    for l in open(a.phon, encoding="utf-8"):
        f = l.rstrip("\n").split("\t")
        if len(f) < 3 or l.startswith("#") or (a.lang and f[1] != a.lang):
            continue
        uid, ps = f[0], f[2]
        x = [0, ids["^"], 0]
        for c in ps:
            if c in ids:
                x += [ids[c], 0]
        x += [ids["$"], 0]
        t0 = time.time()
        mel, dur = am.run(None, {"x": np.array([x], np.int64), "x_length": np.array([len(x)], np.int64),
                                 "noise_scale": np.array([a.noise], np.float32),
                                 "length_scale": np.array([a.length], np.float32)})
        mag, cx, cy = vo.run(None, {"mels": mel.astype(np.float32)})
        S = torch.from_numpy(mag * cx) + 1j * torch.from_numpy(mag * cy)
        y = torch.istft(S, 1024, 256, 1024, win, center=True).numpy()[0]
        el = time.time() - t0
        y = np.clip(y, -1, 1)
        sf.write(os.path.join(a.out, uid + ".wav"), y, 22050, subtype="PCM_16")
        s = len(y) / 22050
        tot_a += s
        tot_t += el
        print(f"{uid}\t{s:.2f} s\t{el:.3f} s\tRTF {el / s:.3f}", flush=True)
    print(f"total {tot_a:.1f} s audio, RTF {tot_t / max(tot_a, 1e-9):.3f} ({a.threads} threads)")


main()
