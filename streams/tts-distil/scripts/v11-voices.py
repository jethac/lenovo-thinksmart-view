#!/usr/bin/env python3
"""Which Kokoro-82M-v1.1-zh voice (or blend) is closest to the persona's
Mandarin voice (v1.0 zf_xiaoni*0.7+af_heart*0.3)? Renders the given lines
in every candidate (fp32, CUDA, the model card's speed curve) and compares
each candidate's renders, pooled, to the reference renders of the same
lines: RMS difference of the level-normalised long-term average spectrum
(64 mel bands, dB) and the distance of the mean MFCC 1-12 (as eval.py), and
the median voiced F0.

    v11-voices.py V11_DIR PHON.tsv REF_DIR OUT_DIR VOICE...   (VOICE: a name, a blend, or "zf_*")
"""
import glob, os, sys, zlib
import librosa, numpy as np, soundfile as sf, torch
from kokoro.model import KModel

kdir, phon, ref, out = sys.argv[1:5]
specs = []
for v in sys.argv[5:]:
    specs += sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(kdir, "voices", v + ".pt"))) if "*" in v and "+" not in v else [v]
dev = "cuda" if torch.cuda.is_available() else "cpu"
model = KModel(config=os.path.join(kdir, "config.json"), model=os.path.join(kdir, "kokoro-v1_1-zh.pth")).to(dev).eval()
rows = [l.rstrip("\n").split("\t") for l in open(phon, encoding="utf-8") if l.count("\t") >= 2]


def pack(spec):
    parts = []
    for p in spec.split("+"):
        n, w = (p.split("*") + ["1"])[:2]
        parts.append((torch.load(os.path.join(kdir, "voices", f"{n.strip()}.pt"), weights_only=True), float(w)))
    tot = sum(w for _, w in parts)
    return sum(v * (w / tot) for v, w in parts).to(dev)


def trim(y):
    return librosa.effects.trim(y, top_db=40)[0]


def spectrum(ys):
    m = np.concatenate([librosa.feature.melspectrogram(y=trim(y), sr=22050, n_fft=1024, hop_length=256, n_mels=64) for y in ys], axis=1)
    ltas = 10 * np.log10(m.mean(1) + 1e-10)
    ltas -= ltas.mean()
    return ltas, librosa.feature.mfcc(S=librosa.power_to_db(m), n_mfcc=13)[1:].mean(1)


def f0(ys):
    v = []
    for y in ys:
        f, vf, _ = librosa.pyin(y, fmin=70, fmax=500, sr=22050)
        v += list(f[vf])
    return float(np.median(v)) if v else float("nan")


load = lambda p: librosa.resample(sf.read(p, dtype="float32")[0], orig_sr=24000, target_sr=22050)
R = [load(os.path.join(ref, r[0] + ".wav")) for r in rows]
rl, rm = spectrum(R)
print(f"reference\tF0 {f0(R):.0f}")
vocab = model.vocab
res = []
for s in specs:
    pk, ys = pack(s), []
    d = os.path.join(out, s.replace("*", "x").replace("+", "_"))
    os.makedirs(d, exist_ok=True)
    for r in rows:
        ids = [vocab[c] for c in r[2] if c in vocab][:510]
        n = len(ids)
        sp = 1.1 * (1 if n <= 83 else 1 - (n - 83) / 500 if n < 183 else 0.8)
        torch.manual_seed(zlib.crc32(r[0].encode()))
        with torch.no_grad():
            a, _ = model.forward_with_tokens(torch.LongTensor([[0, *ids, 0]]).to(dev), pk[n - 1], sp)
        a = a.float().cpu().numpy()
        sf.write(os.path.join(d, r[0] + ".wav"), a, 24000, subtype="PCM_16")
        ys.append(librosa.resample(a, orig_sr=24000, target_sr=22050))
    l, m = spectrum(ys)
    res.append((float(np.sqrt(np.mean((l - rl) ** 2))), float(np.linalg.norm(m - rm)), f0(ys), s))
    print(f"{s}\tLTAS {res[-1][0]:.2f} dB\tMFCC {res[-1][1]:.2f}\tF0 {res[-1][2]:.0f}", flush=True)
print("# closest (MFCC distance):")
for r in sorted(res, key=lambda r: r[1])[:10]:
    print(f"# {r[3]}\tLTAS {r[0]:.2f}\tMFCC {r[1]:.2f}\tF0 {r[2]:.0f}")
