#!/usr/bin/env python3
"""Train a Vocos vocoder from scratch on the Kokoro renders (22.05 kHz),
for the Matcha students' mel spectrograms (80 bins, n_fft 1024, hop 256,
fmax 8 kHz, log with a 1e-5 floor: Matcha's own mel function), with the
output the device's Rust inverse STFT expects (magnitude, cos, sin; n_fft
1024, hop 256, Hann, centred).

    train-vocos.py FILELIST VALID_LIST OUT_DIR [--steps N] [--batch B]

Model and losses are gemelo-ai/vocos (MIT): ConvNeXt backbone (dim 512,
intermediate 1536, 8 layers), ISTFT head; multi-period and multi-resolution
discriminators; mel L1 (x45), MRD weight 0.1, AdamW 5e-4 (0.8, 0.9) with a
cosine schedule, as its reference config; but 8192-sample segments (not
16384) and bf16 autocast for the backbone and the discriminators (the
discriminators dominate the step on the shared GB10). A plain PyTorch loop (the
reference training code targets Lightning 1.8).
"""
import argparse, glob, math, os, random, sys, time
import numpy as np
import soundfile as sf
import torch
import torch.nn.functional as F

sys.path.insert(0, "/w/downloads/vocos")
sys.path.insert(0, "/w/downloads/Matcha-TTS")
from vocos.models import VocosBackbone  # noqa: E402
from vocos.heads import ISTFTHead  # noqa: E402
from vocos.discriminators import MultiPeriodDiscriminator, MultiResolutionDiscriminator  # noqa: E402
from vocos.loss import DiscriminatorLoss, GeneratorLoss, FeatureMatchingLoss, MelSpecReconstructionLoss  # noqa: E402
from matcha.utils.audio import mel_spectrogram  # noqa: E402

SR, HOP = 22050, 256
# Matcha's frame t is centred on sample t * 256 + 128 (reflect pad 384,
# window 1024, not centred); the ISTFT's frame t on sample t * 256. So
# output sample n is input sample n + 128.
SHIFT = 128


def mel(y):
    return mel_spectrogram(y, 1024, 80, SR, HOP, 1024, 0, 8000, center=False)


class Data(torch.utils.data.Dataset):
    def __init__(self, files, n, train=True):
        self.files, self.n, self.train = files, n, train

    def __len__(self):
        return len(self.files)

    def __getitem__(self, i):
        y, sr = sf.read(self.files[i], dtype="float32")
        assert sr == SR
        if self.train:
            gain = 10 ** (random.uniform(-6, -1) / 20)
            y = y / max(np.abs(y).max(), 1e-4) * gain
        n = self.n
        if len(y) < n:
            y = np.pad(y, (0, n - len(y)))
        s = random.randint(0, len(y) - n) if self.train else 0
        return torch.from_numpy(np.ascontiguousarray(y[s:s + n]))


class Vocos(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = VocosBackbone(input_channels=80, dim=512, intermediate_dim=1536, num_layers=8)
        self.head = ISTFTHead(dim=512, n_fft=1024, hop_length=HOP, padding="center")

    def forward(self, m):
        # The backbone in bf16 when autocast is on; the head (linear and
        # inverse STFT) in fp32.
        h = self.backbone(m)
        with torch.autocast("cuda", enabled=False):
            return self.head(h.float())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("train")
    ap.add_argument("valid")
    ap.add_argument("out")
    ap.add_argument("--steps", type=int, default=1000000)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--samples", type=int, default=8192)
    ap.add_argument("--every", type=int, default=10000)
    ap.add_argument("--workers", type=int, default=5)
    a = ap.parse_args()
    frac = float(os.environ.get("TORCH_MEM_FRACTION", "0") or 0)
    if frac:
        torch.cuda.set_per_process_memory_fraction(frac)
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    torch.backends.cudnn.benchmark = True
    dev = "cuda"
    os.makedirs(a.out, exist_ok=True)
    tr = [l.split("|")[0].strip() for l in open(a.train) if l.strip()]
    va = [l.split("|")[0].strip() for l in open(a.valid) if l.strip()][:16]
    dl = torch.utils.data.DataLoader(Data(tr, a.samples), batch_size=a.batch, shuffle=True, num_workers=a.workers,
                                     drop_last=True, persistent_workers=True, pin_memory=True)
    g = Vocos().to(dev)
    mpd, mrd = MultiPeriodDiscriminator().to(dev), MultiResolutionDiscriminator().to(dev)
    og = torch.optim.AdamW(g.parameters(), lr=5e-4, betas=(0.8, 0.9))
    od = torch.optim.AdamW(list(mpd.parameters()) + list(mrd.parameters()), lr=5e-4, betas=(0.8, 0.9))
    lr = lambda s: 0.5 * (1 + math.cos(math.pi * min(s, a.steps) / a.steps))
    sg, sd = torch.optim.lr_scheduler.LambdaLR(og, lr), torch.optim.lr_scheduler.LambdaLR(od, lr)
    dloss, gloss, fml = DiscriminatorLoss(), GeneratorLoss(), FeatureMatchingLoss()
    mloss = MelSpecReconstructionLoss(sample_rate=SR, n_mels=80).to(dev)
    step = 0
    cks = sorted(glob.glob(os.path.join(a.out, "step-*.pt")))
    if cks:
        ck = torch.load(cks[-1], map_location=dev)
        g.load_state_dict(ck["g"]); mpd.load_state_dict(ck["mpd"]); mrd.load_state_dict(ck["mrd"])
        og.load_state_dict(ck["og"]); od.load_state_dict(ck["od"]); sg.load_state_dict(ck["sg"]); sd.load_state_dict(ck["sd"])
        step = ck["step"]
        print("resumed", cks[-1], flush=True)
    print("generator params", sum(p.numel() for p in g.parameters()), flush=True)
    t0, acc = time.time(), {}
    while step < a.steps:
        for y in dl:
            y = y.to(dev, non_blocking=True)
            with torch.no_grad():
                m = mel(y)
            yt = y[:, SHIFT:SHIFT + (m.shape[-1] - 1) * HOP]
            with torch.autocast("cuda", dtype=torch.bfloat16):
                yh = g(m)
            n = min(yh.shape[-1], yt.shape[-1])
            yh, yt = yh[:, :n], yt[:, :n]
            # discriminators
            with torch.autocast("cuda", dtype=torch.bfloat16):
                rp, gp, _, _ = mpd(y=yt, y_hat=yh.detach())
                rr, gr, _, _ = mrd(y=yt, y_hat=yh.detach())
            rp, gp, rr, gr = ([t.float() for t in v] for v in (rp, gp, rr, gr))
            lp, lpr, _ = dloss(disc_real_outputs=rp, disc_generated_outputs=gp)
            lr_, lrr, _ = dloss(disc_real_outputs=rr, disc_generated_outputs=gr)
            ld = lp / len(lpr) + 0.1 * lr_ / len(lrr)
            od.zero_grad(set_to_none=True)
            ld.backward()
            od.step()
            # generator
            with torch.autocast("cuda", dtype=torch.bfloat16):
                _, gp, fr_p, fg_p = mpd(y=yt, y_hat=yh)
                _, gr, fr_r, fg_r = mrd(y=yt, y_hat=yh)
            f32 = lambda v: [t.float() for t in v]
            gp, gr = f32(gp), f32(gr)
            fr_p, fg_p, fr_r, fg_r = ([f32(x) for x in v] for v in (fr_p, fg_p, fr_r, fg_r))
            lgp, l1 = gloss(disc_outputs=gp)
            lgr, l2 = gloss(disc_outputs=gr)
            lfp = fml(fmap_r=fr_p, fmap_g=fg_p) / len(fr_p)
            lfr = fml(fmap_r=fr_r, fmap_g=fg_r) / len(fr_r)
            lm = mloss(yh, yt)
            lg = lgp / len(l1) + 0.1 * lgr / len(l2) + lfp + 0.1 * lfr + 45 * lm
            og.zero_grad(set_to_none=True)
            lg.backward()
            torch.nn.utils.clip_grad_norm_(g.parameters(), 1000.0)
            og.step()
            sg.step(); sd.step()
            step += 1
            for k, v in (("d", ld), ("g", lg), ("mel", lm)):
                acc[k] = acc.get(k, 0.0) + v.item()
            if step % 200 == 0:
                el = time.time() - t0
                print(f"step {step} " + " ".join(f"{k} {v / 200:.4f}" for k, v in acc.items()) +
                      f" {200 / el:.2f} it/s", flush=True)
                acc, t0 = {}, time.time()
            if step % a.every == 0 or step >= a.steps:
                ck = dict(g=g.state_dict(), mpd=mpd.state_dict(), mrd=mrd.state_dict(), og=og.state_dict(),
                          od=od.state_dict(), sg=sg.state_dict(), sd=sd.state_dict(), step=step)
                torch.save(ck, os.path.join(a.out, f"step-{step:07d}.pt"))
                for old in sorted(glob.glob(os.path.join(a.out, "step-*.pt")))[:-2]:
                    if int(old[-10:-3]) % 100000:
                        os.remove(old)  # keep the last two and every 100k
                torch.save(g.state_dict(), os.path.join(a.out, f"g-{step:07d}.pt"))
                g.eval()
                d = os.path.join(a.out, f"samples-{step:07d}")
                os.makedirs(d, exist_ok=True)
                tot = 0.0
                with torch.no_grad():
                    for f in va:
                        y0, _ = sf.read(f, dtype="float32")
                        y0 = torch.from_numpy(y0)[None].to(dev)
                        m0 = mel(y0)
                        yh0 = g(m0)
                        t = y0[:, SHIFT:SHIFT + yh0.shape[-1]]
                        tot += mloss(yh0[:, :t.shape[-1]], t).item()
                        sf.write(os.path.join(d, os.path.basename(f)), yh0[0].cpu().numpy(), SR, subtype="PCM_16")
                print(f"valid step {step} mel_l1 {tot / len(va):.4f}", flush=True)
                g.train()
            if step >= a.steps:
                break


main()
