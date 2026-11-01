#!/usr/bin/env python3
"""Render the corpus with Kokoro-82M v1.0 (fp32, CUDA) from the device front
end's phonemes, as the tablet would say it: the same phoneme string, the
same style row (pack[n_tokens - 1]) of the same voice blend, speed 1.

    kokoro-render.py KOKORO_DIR PHON.tsv VOICE OUTDIR [--shard I/N] [--reverse]

PHON.tsv is `straylight-listen --g2p` output (id, lang, phonemes, ms).
VOICE is a name or blend "jf_alpha*0.7+af_heart*0.3".
Writes OUTDIR/wav24/<id>.flac (24 kHz, PCM 16), OUTDIR/dur/<id>.npy (Kokoro's
per-token durations in 600-sample frames, the two pads included) and
OUTDIR/render-<shard>.tsv (id, seconds, tokens, phonemes).
Lines that are already rendered are skipped, so it can be restarted.
"""
import os, sys, time, zlib
import numpy as np
import soundfile as sf
import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "kokoro_pkg"))
from kokoro.model import KModel  # noqa: E402


def voice_pack(d, spec):
    parts = []
    for p in spec.split("+"):
        n, w = (p.split("*") + ["1"])[:2]
        parts.append((torch.load(os.path.join(d, "voices", f"{n.strip()}.pt"), weights_only=True), float(w)))
    tot = sum(w for _, w in parts)
    return sum(v * (w / tot) for v, w in parts)


def main():
    kdir, phon, voice, out = sys.argv[1:5]
    shard, nsh = 0, 1
    if "--shard" in sys.argv:
        shard, nsh = map(int, sys.argv[sys.argv.index("--shard") + 1].split("/"))
    os.makedirs(os.path.join(out, "wav24"), exist_ok=True)
    os.makedirs(os.path.join(out, "dur"), exist_ok=True)
    dev = "cuda"
    model = KModel(config=os.path.join(kdir, "config.json"), model=os.path.join(kdir, "kokoro-v1_0.pth")).to(dev).eval()
    pack = voice_pack(kdir, voice).to(dev)
    vocab = model.vocab
    log = open(os.path.join(out, f"render-{shard}{'r' if '--reverse' in sys.argv else ''}.tsv"), "a", encoding="utf-8")
    t0, done, secs = time.time(), 0, 0.0
    rows = [l.rstrip("\n").split("\t") for l in open(phon, encoding="utf-8")]
    order = list(enumerate(rows))
    if "--reverse" in sys.argv:
        order.reverse()  # a second worker from the other end
    for k, f in order:
        if k % nsh != shard or len(f) < 3:
            continue
        uid, ps = f[0], f[2].strip()
        wav = os.path.join(out, "wav24", f"{uid}.flac")
        if os.path.exists(wav):
            continue
        ids = [vocab[c] for c in ps if c in vocab]
        if not ids or len(ids) > 510:
            continue
        ref = pack[len(ids) - 1]
        torch.manual_seed(zlib.crc32(uid.encode()))
        x = torch.LongTensor([[0, *ids, 0]]).to(dev)
        with torch.no_grad():
            audio, dur = model.forward_with_tokens(x, ref, 1.0)
        a = audio.float().cpu().numpy()
        np.save(os.path.join(out, "dur", f"{uid}.npy"), dur.cpu().numpy().astype(np.int16))
        sf.write(wav, a, 24000, subtype="PCM_16")
        s = len(a) / 24000
        secs += s
        done += 1
        log.write(f"{uid}\t{s:.3f}\t{len(ids)}\t{ps}\n")
        if done % 200 == 0:
            log.flush()
            el = time.time() - t0
            print(f"{voice} shard {shard}: {done} lines, {secs / 3600:.2f} h audio, {el:.0f} s, x{secs / el:.1f} real time", flush=True)
    log.close()
    print(f"done {done} lines {secs / 3600:.2f} h in {time.time() - t0:.0f} s", flush=True)


main()
