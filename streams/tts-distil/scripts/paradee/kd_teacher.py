#!/usr/bin/env python3
"""Paradee's teacher corpus from our sentences: Kokoro-82M v1.0 reads the
device front end's phonemes in our voice (a name or blend) and every
intermediate the student scripts read is stored, in shards of 500 rows,
as upstream gen_teacher.py does (ids, dur, pred_dur, t_en, F0, N, audio,
ps, text = our line id). Differences: the input is our phoneme TSV, not
misaki on WikiText; the rows are shuffled (seed 1) so the 200 held-out
rows of shard 0 mix every source; the phoneme features d (unused by the
trainers) are not kept; the harmonic source's STFT runs on the CPU and
each row has a fixed seed, so the audio is the CPU teacher's (upstream
regen_audio.py) without a second pass.

    kd_teacher.py PHON.tsv VOICE OUT_DIR      (run in the training image)

KD_PART=i/n makes this worker render only shards k with k % n == i, so n
workers can share one GPU (each is bound by per-sentence latency).
KD_REVERSE=1 renders the shards from the last one down, so a second machine
can work from the other end (finished shards are copied between them and
skipped, as any existing shard is).
"""
import os, random, sys, time, zlib
import torch
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
os.environ["PARADEE_VOICE"] = sys.argv[2]
from teacher_shim import KPipeline  # noqa: E402
from common import cpu_source_stft  # noqa: E402

SHARD = 500
phon, voice, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
dev = "cuda"
pipe = KPipeline(device=dev)
m = pipe.model
cpu_source_stft(m.decoder)
ref = pipe.load_voice(voice).to(dev)
rows = [l.rstrip("\n").split("\t") for l in open(phon, encoding="utf-8")]
rows = [(f[0], f[2].strip()) for f in rows if len(f) >= 3 and f[2].strip()]
random.Random(1).shuffle(rows)


@torch.no_grad()
def run(uid, ps):
    ids = torch.LongTensor([[0, *[m.vocab[c] for c in ps if c in m.vocab], 0]]).to(dev)
    T = ids.shape[1]
    r = ref[T - 3]
    L = torch.full((1,), T, device=dev)
    mask = torch.zeros(1, T, dtype=torch.bool, device=dev)
    bert_dur = m.bert(ids, attention_mask=(~mask).int())
    d_en = m.bert_encoder(bert_dur).transpose(-1, -2)
    s = r[:, 128:]
    d = m.predictor.text_encoder(d_en, s, L, mask)
    x, _ = m.predictor.lstm(d)
    dur = torch.sigmoid(m.predictor.duration_proj(x)).sum(-1)
    pred_dur = torch.round(dur).clamp(min=1).long().squeeze(0)
    idx = torch.repeat_interleave(torch.arange(T, device=dev), pred_dur)
    aln = torch.zeros(T, idx.shape[0], device=dev)
    aln[idx, torch.arange(idx.shape[0])] = 1
    aln = aln[None]
    en = d.transpose(-1, -2) @ aln
    F0, Nn = m.predictor.F0Ntrain(en, s)
    t_en = m.text_encoder(ids, L, mask)
    asr = t_en @ aln
    torch.manual_seed(zlib.crc32(uid.encode()))
    audio = m.decoder(asr, F0, Nn, r[:, :128]).squeeze()
    c = lambda t: t.squeeze(0).cpu()
    return dict(ids=c(ids), dur=c(dur), pred_dur=pred_dur.cpu(), t_en=c(t_en).half(), F0=c(F0), N=c(Nn),
                audio=(audio.cpu().clamp(-1, 1) * 32767).short(), audio_cpu=True)


part, nparts = map(int, os.environ.get("KD_PART", "0/1").split("/"))
t0, secs = time.time(), 0.0
order = range(0, len(rows), SHARD)
if os.environ.get("KD_REVERSE") == "1":
    order = reversed(order)
for sh in order:
    path = os.path.join(out, f"shard_{sh // SHARD:04d}.pt")
    if os.path.exists(path) or (sh // SHARD) % nparts != part:
        continue
    acc = []
    for uid, ps in rows[sh:sh + SHARD]:
        n = sum(c in m.vocab for c in ps)
        if not n or n > 400:
            continue
        r = run(uid, ps)
        r["text"], r["ps"] = uid, ps
        acc.append(r)
        secs += len(r["audio"]) / 24000
    torch.save(acc, path + ".tmp")
    os.replace(path + ".tmp", path)
    print(f"{path} {len(acc)} rows {secs / 3600:.2f} h audio {time.time() - t0:.0f} s", flush=True)
print("done", flush=True)
