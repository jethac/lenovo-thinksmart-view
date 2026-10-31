"""Evaluate a trained model on held-out data.

    eval.py MODELDIR [--thresholds 0.3,0.5,...] [--patience 1]

Recall: the share of held-out positive clips (work/feat/utt-*-pos-test*.npy:
Piper voices never used in training, and Magpie's Sofia plus unseen seeds of
the others) that the detector fires on. Per clip there are the 4
consecutive windows a streaming detector sees once the phrase has ended
(80 ms apart, the first 0-80 ms after the end); a hit is `patience` of them
in a row at or above the threshold. "-clean" sets are not augmented (level
only); the others have noise, music, reverb and EQ as in training.

Near misses: the share of held-out near-miss windows (hey, Straylight alone,
other assistants' names, "hey starlight", ...) that score at or above it.

False accepts per hour: work/long-emb/*.emb, straylight-listen's embeddings
of long held-out audio (LibriSpeech test-clean, FLEURS ja and zh test, MUSAN
music shard 2), scored every 80 ms with the same rule as the daemon
(`patience` frames in a row at or above the threshold fire, then 2 s of
refractory), counted per hour of audio. openWakeWord's false-positive
validation set (11.3 h) is reported too, though checkpoint selection saw it.

Prints a table and writes MODELDIR/eval-p<patience>.json.
"""
import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import onnxruntime as ort

S = Path(__file__).resolve().parent.parent
FEAT = S / "work/feat"
LONG = S / "work/long-emb"


def windows(e):
    from numpy.lib.stride_tricks import sliding_window_view
    return sliding_window_view(e, (16, 96))[:, 0]


def score(sess, X, bs=16384):
    out = []
    for i in range(0, len(X), bs):
        out.append(sess.run(None, {"input": np.asarray(X[i:i + bs], np.float32)})[0][:, 0])
    return np.concatenate(out) if out else np.zeros(0)


def events(sc, thr, patience=1, refractory=25):
    n, run, hold = 0, 0, 0
    for v in sc:
        if hold:
            hold -= 1
            run = 0
            continue
        if v >= thr:
            run += 1
            if run >= patience:
                n += 1
                run = 0
                hold = refractory
        else:
            run = 0
    return n


def utt_hits(sc, thr, patience):
    """sc: (clips, 4) scores of consecutive windows; a hit is `patience` in a row."""
    above = sc >= thr
    if patience == 1:
        return above.any(axis=1)
    run = np.zeros(len(sc), int)
    hit = np.zeros(len(sc), bool)
    for j in range(sc.shape[1]):
        run = np.where(above[:, j], run + 1, 0)
        hit |= run >= patience
    return hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--thresholds", default="0.3,0.4,0.5,0.6,0.7,0.8,0.9")
    ap.add_argument("--patience", type=int, default=1)
    a = ap.parse_args()
    md = Path(a.model)
    thr = [float(x) for x in a.thresholds.split(",")]
    sess = ort.InferenceSession(str(md / "hey-straylight.onnx"))
    res = {"thresholds": thr, "patience": a.patience, "recall": {}, "near_miss": {}, "fa_per_hour": {}}

    for f in sorted(FEAT.glob("utt-*-pos-test*.npy")):
        sc = score(sess, np.load(f, mmap_mode="r")).reshape(-1, 4)
        res["recall"][f.stem] = {"n": len(sc), **{str(t): float(utt_hits(sc, t, a.patience).mean()) for t in thr}}
    for f in sorted(FEAT.glob("*-neg-test*.npy")):
        sc = score(sess, np.load(f, mmap_mode="r"))
        res["near_miss"][f.stem] = {"n": len(sc), **{str(t): float((sc >= t).mean()) for t in thr}}

    groups = defaultdict(list)
    for f in sorted(LONG.glob("*.emb")):
        groups[f.stem.rsplit("-", 1)[0]].append(f)
    fpv = S / "downloads/negatives/validation_set_features.npy"
    sets = {k: v for k, v in groups.items()}
    for name, files in list(sets.items()) + [("oww-fp-validation", [fpv])]:
        hours, counts = 0.0, defaultdict(int)
        for f in files:
            e = np.load(f) if f.suffix == ".npy" else np.fromfile(f, "<f4").reshape(-1, 96)
            hours += len(e) * 0.08 / 3600
            sc = score(sess, windows(e))
            for t in thr:
                counts[t] += events(sc, t, a.patience)
        res["fa_per_hour"][name] = {"hours": hours, **{str(t): counts[t] / hours for t in thr}}

    print(f"model {md}, patience {a.patience}")
    print("set".ljust(28) + "".join(f"{t:>8}" for t in thr))
    for kind in ("recall", "near_miss", "fa_per_hour"):
        print(f"-- {kind}")
        for k, v in res[kind].items():
            size = f"({v['hours']:.1f} h)" if "hours" in v else f"({v['n']})"
            print(f"{k} {size}".ljust(28) + "".join(f"{v[str(t)]:8.3f}" for t in thr))
    json.dump(res, open(md / f"eval-p{a.patience}.json", "w"), indent=1)


if __name__ == "__main__":
    main()
