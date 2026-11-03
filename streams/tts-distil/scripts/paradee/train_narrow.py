#!/usr/bin/env python3
"""Train a narrow Kokoro decoder (narrow.py) on the teacher corpus
(kd_teacher.py shards): the teacher's own text-side outputs (aligned
features, F0, energy) and its style row in, the teacher's audio as the
target. Paradee's decoder recipe (train_decoder.py): log-mel L1 plus
multi-resolution STFT losses, then (--gan) MPD + multi-resolution
spectrogram discriminators with feature matching and the spectral losses
weighted by --mel-weight. Held-out = the first 200 rows of shard 0.

    train_narrow.py WIDTH [--steps N] [--gan --mel-weight W --init-from CKPT] [--tag T]

Run from a voice's working directory (data/teacher, checkpoints/), with
PARADEE_VOICE set to the teacher voice. Resumable from
checkpoints/narrow_WIDTH{tag}/last.pt; a snapshot of the generator every
--every steps (step-NNNNNNN.pt) with held-out WAVs and a DTW log-mel
distance to the teacher, so the best point of the curve can be picked.
"""
import argparse, glob, json, math, os, random, sys, time, warnings
warnings.filterwarnings("ignore")
import torch, torch.nn.functional as F, soundfile as sf, torchaudio
sys.path.insert(0, "scripts")
from narrow import StyledDecoder, conv_stft
from student import alignment
from common import cpu_source_stft, compare
from teacher_shim import voice_pack

ap = argparse.ArgumentParser()
ap.add_argument("width")
ap.add_argument("--steps", type=int, default=30000)
ap.add_argument("--bs", type=int, default=16)
ap.add_argument("--lr", type=float, default=2e-4)
ap.add_argument("--seg", type=int, default=64)
ap.add_argument("--gan", action="store_true")
ap.add_argument("--mel-weight", type=float, default=45.0)
ap.add_argument("--fm-weight", type=float, default=2.0)
ap.add_argument("--init-from", default="")
ap.add_argument("--every", type=int, default=2000)
ap.add_argument("--shards", type=int, default=999)
ap.add_argument("--tag", default="")
ap.add_argument("--device", default="cuda")
ap.add_argument("--teacher-source", action="store_true",
                help="copy the teacher's harmonic-source mixing layer (it runs under no_grad, so it never trains)")
ap.add_argument("--head-weight", type=float, default=0.0,
                help="distil the teacher's iSTFT head: L1 on its log-magnitude output, with the same excitation (implies --teacher-source)")
ap.add_argument("--phase-weight", type=float, default=0.0,
                help="L1 on the sine of the teacher's head phase output, same excitation")
A = ap.parse_args()
DEV = A.device
RUN = f"checkpoints/narrow_{A.width}{A.tag}"
os.makedirs(RUN, exist_ok=True)

PACK = voice_pack(os.environ.get("PARADEE_VOICE", "af_heart"))  # [510, 1, 256]


def load_rows():
    shards = sorted(glob.glob("data/teacher/shard_*.pt"))[:A.shards]
    out = []
    for sh in shards:
        for r in torch.load(sh):
            r["n_ids"] = len(r["ids"])
            for k in ("ids", "dur", "d", "audio_mps"):
                r.pop(k, None)
            out.append(r)
    return out[:200], out[200:], len(shards)


held, train, nsh = load_rows()
print(f"{len(train)} train / {len(held)} held-out rows from {nsh} shards", flush=True)


def style(r):
    return PACK[r["n_ids"] - 3][0, :128]


def full(r):
    # the aligned features: each token's column repeated for its frames
    # (the same as t_en @ alignment, without the dense matrix)
    idx = torch.repeat_interleave(torch.arange(len(r["pred_dur"])), r["pred_dur"])
    Fr = len(idx)
    return r["t_en"][:, idx].float(), r["F0"][:2 * Fr], r["N"][:2 * Fr], r["audio"][:600 * Fr].float() / 32767


def segment(r, seg):
    if "idx" not in r:
        r["idx"] = torch.repeat_interleave(torch.arange(len(r["pred_dur"])), r["pred_dur"])
    idx = r["idx"]
    Fr = len(idx)
    if Fr <= seg:
        asr, F0, N, au = full(r)
        p = seg - Fr
        return F.pad(asr, (0, p)), F.pad(F0, (0, 2 * p)), F.pad(N, (0, 2 * p)), F.pad(au, (0, 600 * p)), style(r)
    a = random.randint(0, Fr - seg)
    return (r["t_en"][:, idx[a:a + seg]].float(), r["F0"][2 * a:2 * (a + seg)], r["N"][2 * a:2 * (a + seg)],
            r["audio"][600 * a:600 * (a + seg)].float() / 32767, style(r))


def collate(rows):
    x = [segment(r, A.seg) for r in rows]
    return [torch.stack([t[i] for t in x]).to(DEV) for i in range(5)]


mel = torchaudio.transforms.MelSpectrogram(24000, n_fft=1024, hop_length=256, n_mels=80).to(DEV)


def spec_losses(y, t):
    lm = F.l1_loss(torch.log(mel(y).clamp_min(1e-5)), torch.log(mel(t).clamp_min(1e-5)))
    ls = 0
    for n in (512, 1024, 2048):
        w = torch.hann_window(n, device=DEV)
        Y = torch.stft(y, n, n // 4, window=w, return_complex=True).abs()
        T = torch.stft(t, n, n // 4, window=w, return_complex=True).abs()
        ls = ls + (T - Y).norm() / T.norm().clamp_min(1e-5) + F.l1_loss(torch.log(Y.clamp_min(1e-5)), torch.log(T.clamp_min(1e-5)))
    return lm, ls / 3


model = StyledDecoder(A.width).to(DEV)
HEAD = A.head_weight > 0 or A.phase_weight > 0
TSRC = None
if A.teacher_source or HEAD:
    from teacher_shim import KPipeline
    _t = KPipeline(device="cpu").model
    TSRC = {k: v.clone() for k, v in _t.decoder.generator.m_source.state_dict().items()}
    if HEAD:
        # the frozen teacher decoder, run on the same inputs and excitation; hooks
        # keep both heads' outputs (before exp and sin)
        TDEC = _t.decoder.to(DEV).eval().requires_grad_(False)
        conv_stft(TDEC)
        CAP = {}
        TDEC.generator.conv_post.register_forward_hook(lambda m, i, o: CAP.__setitem__("t", o))
        model.generator.conv_post.register_forward_hook(lambda m, i, o: CAP.__setitem__("s", o))
    del _t
conv_stft(model)
opt = torch.optim.AdamW(model.parameters(), lr=A.lr, betas=(0.8, 0.99), weight_decay=0.01)
sched = lambda s: min(1, s / 1000) * 0.5 * (1 + math.cos(math.pi * min(s, A.steps) / A.steps))
if A.gan:
    from discriminators import Discriminators, d_loss, g_loss
    D = Discriminators().to(DEV)
    optD = torch.optim.AdamW(D.parameters(), lr=A.lr, betas=(0.8, 0.99), weight_decay=0.01)
step, last = 0, f"{RUN}/last.pt"
if os.path.exists(last):
    ck = torch.load(last, map_location=DEV)
    model.load_state_dict(ck["model"]); opt.load_state_dict(ck["opt"]); step = ck["step"]
    if A.gan and "D" in ck:
        D.load_state_dict(ck["D"]); optD.load_state_dict(ck["optD"])
    print(f"resumed at {step}", flush=True)
elif A.init_from:
    res = model.load_state_dict(torch.load(A.init_from, map_location=DEV)["model"])
    print(f"initialised from {A.init_from}: {res}", flush=True)
if TSRC is not None:
    model.generator.m_source.load_state_dict({k: v.to(DEV) for k, v in TSRC.items()})
    print("harmonic source mixing from the teacher", flush=True)


@torch.no_grad()
def evaluate(n=8):
    model.eval()
    d = f"{RUN}/eval-{step:07d}"
    os.makedirs(d, exist_ok=True)
    outs, refs = [], []
    for i, r in enumerate(held[:n]):
        asr, F0, N, au = full(r)
        torch.manual_seed(i)
        y = model(asr[None].to(DEV), F0[None].to(DEV), N[None].to(DEV), style(r)[None].to(DEV)).squeeze().cpu()
        k = min(len(y), len(au))
        outs.append(y[:k]); refs.append(au[:k])
        sf.write(f"{d}/held_{i + 1}.wav", y.numpy(), 24000)
    raw, dtw, _ = compare(refs, outs)
    model.train()
    return dict(step=step, dtw_l1=round(dtw, 4), raw_l1=round(raw, 4))


print(f"narrow decoder {A.width}: {sum(p.numel() for p in model.parameters()) / 1e6:.2f}M params, {'GAN' if A.gan else 'spectral'} stage", flush=True)
model.train()
t0, s0 = time.time(), step
log = open(f"{RUN}/log.jsonl", "a")
while step < A.steps:
    asr, F0, N, au, sty = collate(random.sample(train, A.bs))
    for g in opt.param_groups:
        g["lr"] = A.lr * sched(step)
    if HEAD:
        seed = random.randrange(1 << 30)
        torch.manual_seed(seed)
        with torch.no_grad():
            TDEC(asr, F0, N, sty)
        torch.manual_seed(seed)  # the same draws for the student's excitation
    y = model(asr, F0, N, sty).squeeze(1)
    k = min(y.shape[-1], au.shape[-1])
    y, au = y[:, :k], au[:, :k]
    lm, ls = spec_losses(y, au)
    l_mag = l_ph = torch.zeros((), device=DEV)
    if HEAD:
        ht, hs = CAP["t"], CAP["s"]
        nb = ht.shape[1] // 2
        k2 = min(ht.shape[-1], hs.shape[-1])
        l_mag = F.l1_loss(hs[:, :nb, :k2], ht[:, :nb, :k2])
        l_ph = F.l1_loss(torch.sin(hs[:, nb:, :k2]), torch.sin(ht[:, nb:, :k2]))
    if A.gan:
        ld = d_loss(D, au, y)
        optD.zero_grad(); ld.backward(); optD.step()
        adv, fm = g_loss(D, au, y)
        loss = A.mel_weight * (lm + ls) + adv + A.fm_weight * fm
    else:
        loss = lm + ls
    loss = loss + A.head_weight * l_mag + A.phase_weight * l_ph
    opt.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0); opt.step()
    step += 1
    if step % 50 == 0:
        print(f"step {step} loss {loss.item():.4f} mel {lm.item():.4f} stft {ls.item():.4f}" +
              (f" adv {adv.item():.3f} fm {fm.item():.3f} d {ld.item():.3f}" if A.gan else "") +
              (f" hmag {l_mag.item():.4f} hph {l_ph.item():.4f}" if HEAD else "") +
              f" {(time.time() - t0) / (step - s0):.2f}s/step", flush=True)
    if step % 500 == 0 or step == A.steps:
        ck = {"model": model.state_dict(), "opt": opt.state_dict(), "step": step}
        if A.gan:
            ck["D"] = D.state_dict(); ck["optD"] = optD.state_dict()
        torch.save(ck, last + ".tmp"); os.replace(last + ".tmp", last)
    if step % A.every == 0 or step == A.steps:
        torch.save({"model": model.state_dict(), "step": step}, f"{RUN}/step-{step:07d}.pt")
        ev = evaluate()
        print("EVAL", json.dumps(ev), flush=True)
        log.write(json.dumps(ev) + "\n"); log.flush()
print("done", flush=True)
