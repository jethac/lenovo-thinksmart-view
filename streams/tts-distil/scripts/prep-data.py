#!/usr/bin/env python3
"""Training data from the Kokoro renders: 22.05 kHz audio, Matcha file
lists, per-token durations in mel frames, and the mel statistics.

    prep-data.py RENDER_DIR OUT_DIR [N_VALID]

RENDER_DIR is kokoro-render.py's output (wav24/, dur/, render-*.tsv).
Writes OUT_DIR/wav/<id>.wav (22.05 kHz PCM 16, soxr VHQ), OUT_DIR/durations/
<id>.npy, OUT_DIR/{train,valid}.txt ("path|phonemes") and OUT_DIR/stats.json.

Durations: Kokoro's alignment (its predicted durations, in 600-sample frames
at 24 kHz, which is exactly how its audio was laid out) moved to the mel
frame grid (256 samples at 22.05 kHz) by rounding the cumulative boundaries.
The student's input is [_ ^ _ p1 _ ... pn _ $ _] (blank between symbols, as
the device builds it); every token gets at least one frame, as at inference
(ceil of a positive duration): each blank one frame taken from the span
before it, ^ and $ Kokoro's start and end pads.
"""
import glob, json, os, random, sys
import numpy as np
import soundfile as sf
import soxr
import torch

sys.path.insert(0, "/w/downloads/Matcha-TTS")
from matcha.utils.audio import mel_spectrogram  # noqa: E402

KOKORO_VOCAB = json.load(open("/w/downloads/hexgrad/config.json"))["vocab"]
SR, HOP = 22050, 256


def mel_durations(kdur, n_mel):
    """kdur: Kokoro durations incl. both pads. Returns durations for the
    2 * (len(kdur)) + 1 interspersed tokens, summing to n_mel."""
    cum = np.concatenate([[0], np.cumsum(kdur)]).astype(np.float64)
    b = np.round(cum * 600 * SR / 24000 / HOP).astype(int)
    b[-1] = n_mel
    b = np.maximum.accumulate(np.minimum(b, n_mel))
    spans = np.diff(b)  # per Kokoro token
    out = [1]  # leading blank, from the start pad
    for k, s in enumerate(spans):
        # token, then its following blank (1 frame)
        if k == 0:
            s -= 1  # the leading blank's frame
        out += [max(s - 1, 1), 1]
    out = np.array(out, dtype=np.int64)
    # Fix the total (the max(..., 1) guards can add frames): trim the longest.
    while out.sum() > n_mel:
        out[int(np.argmax(out))] -= 1
    out[-2] += n_mel - out.sum()
    return out


def main():
    rd, od = sys.argv[1], sys.argv[2]
    nval = int(sys.argv[3]) if len(sys.argv) > 3 else 150
    os.makedirs(os.path.join(od, "wav"), exist_ok=True)
    os.makedirs(os.path.join(od, "durations"), exist_ok=True)
    rows = []
    for t in sorted(glob.glob(os.path.join(rd, "render-*.tsv"))):
        for l in open(t, encoding="utf-8"):
            f = l.rstrip("\n").split("\t")
            if len(f) == 4:
                rows.append(f)
    seen, items = set(), []
    tot, s1, s2, nfr = 0.0, 0.0, 0.0, 0
    for uid, secs, ntok, ps in rows:
        if uid in seen:
            continue
        seen.add(uid)
        a, sr = sf.read(os.path.join(rd, "wav24", f"{uid}.flac"), dtype="float32")
        kd = np.load(os.path.join(rd, "dur", f"{uid}.npy")).astype(np.int64).reshape(-1)
        ids = [c for c in ps if c in KOKORO_VOCAB]
        if len(kd) != len(ids) + 2:
            print("skip (len)", uid, file=sys.stderr)
            continue
        # Kokoro's start and end pads are mostly silence (often 0.3 s or
        # more): keep at most 100 ms before and 150 ms after the speech.
        c0, c1 = max(0, int(kd[0]) - 4), max(0, int(kd[-1]) - 6)
        a = a[c0 * 600:len(a) - c1 * 600]
        kd[0] -= c0
        kd[-1] -= c1
        y = soxr.resample(a, 24000, SR, quality="VHQ").astype(np.float32)
        y = np.clip(y, -1.0, 1.0)
        n_mel = len(y) // HOP
        d = mel_durations(kd, n_mel)
        # Interspersed length: 2 * (n + 2) + 1 (^ and $ count as tokens).
        assert len(d) == 2 * (len(ids) + 2) + 1, (uid, len(d), len(ids))
        if d.min() < 1 or d.sum() != n_mel:
            print("skip (dur)", uid, d.min(), d.sum(), n_mel, file=sys.stderr)
            continue
        wp = os.path.join(od, "wav", f"{uid}.wav")
        sf.write(wp, y, SR, subtype="PCM_16")
        np.save(os.path.join(od, "durations", f"{uid}.npy"), d)
        m = mel_spectrogram(torch.from_numpy(y)[None], 1024, 80, SR, HOP, 1024, 0, 8000, center=False)
        assert m.shape[-1] == n_mel, (m.shape, n_mel)
        s1 += m.sum().item()
        s2 += (m ** 2).sum().item()
        nfr += m.shape[-1]
        tot += len(y) / SR
        items.append(f"{wp}|{ps}")
        if len(items) % 1000 == 0:
            print(len(items), f"{tot / 3600:.2f} h", file=sys.stderr, flush=True)
    random.Random(1).shuffle(items)
    open(os.path.join(od, "valid.txt"), "w").write("\n".join(items[:nval]) + "\n")
    open(os.path.join(od, "train.txt"), "w").write("\n".join(items[nval:]) + "\n")
    mean = s1 / (nfr * 80)
    std = (s2 / (nfr * 80) - mean ** 2) ** 0.5
    json.dump({"mel_mean": mean, "mel_std": std, "hours": tot / 3600, "items": len(items), "frames": nfr},
              open(os.path.join(od, "stats.json"), "w"), indent=1)
    print("done", len(items), f"{tot / 3600:.2f} h", mean, std, file=sys.stderr)


main()
