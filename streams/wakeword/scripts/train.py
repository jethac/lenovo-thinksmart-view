"""Train the "Hey Straylight" classifier on openWakeWord features.

    train.py OUTDIR [--steps N] [--dim D] [--blocks B] [--max-neg-weight W] [--seed S]

Model: openWakeWord's "dnn" head. 16 x 96 embeddings, flattened, then
Linear(1536, D), LayerNorm, ReLU, B blocks of Linear(D, D), LayerNorm and
ReLU, then Linear(D, 1) and a sigmoid. Sizes are set with --dim and --blocks.

Data (work/feat/*.npy from make-features.py, downloads/negatives/):
  positives   piper-pos-train, magpie-pos-train (x3 weight in sampling)
  negatives   piper-neg-train, piper-partial-train, magpie-neg-train,
              magpie-partial-train, bg-train, and openWakeWord's ACAV100M
              features (6 x 250,000 windows of 1.28 s each, about 533 h)
--no-acav leaves the ACAV100M features out (their licence is CC BY-NC-SA
4.0) and --extra-neg names the general negatives used instead (MUSAN speech
windows, CC BY 4.0). Each batch mixes them in fixed numbers. The loss is binary cross-entropy,
with the negatives' weight ramped from 1 to --max-neg-weight over the first
half of training (openWakeWord's approach to pushing false accepts down).

Validation, every 500 steps: recall at 0.5 on 5 % of the positives held out
from training, and false accepts per hour at 0.5 on openWakeWord's
false-positive validation set (11.3 h of dinner-party speech, conversation
and music; a window every 80 ms, a detection being a run of windows at or
above the threshold, counted once). The checkpoint kept is the one with the
best recall among those under 0.5 false accepts per hour on it (or the
lowest false-accept rate if none is). Test sets are not looked at here.

Dropout (--dropout, on the input and every hidden layer) and AdamW weight
decay (--weight-decay) are optional. Checkpoints every 2500 steps go to
OUTDIR/ckpt-STEP.pt (export.py turns one into a model).

Output: OUTDIR/model.pt, OUTDIR/hey-straylight.slt (for straylight-listen),
OUTDIR/hey-straylight.onnx, OUTDIR/history.tsv.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, "/home/jethac/Projects/straylight-voice/listen/scripts")
import tensors  # noqa: E402

S = Path(__file__).resolve().parent.parent
FEAT = S / "work/feat"
NEG = S / "downloads/negatives"


class Head(nn.Module):
    def __init__(self, dim, blocks, frames=16, dropout=0.0):
        super().__init__()
        self.drop = nn.Dropout(dropout)
        self.inp = nn.Linear(frames * 96, dim)
        self.ln = nn.LayerNorm(dim)
        self.blocks = nn.ModuleList([nn.Linear(dim, dim) for _ in range(blocks)])
        self.blns = nn.ModuleList([nn.LayerNorm(dim) for _ in range(blocks)])
        self.out = nn.Linear(dim, 1)

    def forward(self, x):  # logits
        x = self.drop(torch.relu(self.ln(self.inp(self.drop(x.flatten(1))))))
        for l, n in zip(self.blocks, self.blns):
            x = self.drop(torch.relu(n(l(x))))
        return self.out(x).squeeze(-1)


def load(name, required=True):
    p = FEAT / f"{name}.npy"
    if not p.exists():
        if required:
            raise SystemExit(f"missing {p}")
        print(f"(no {name})")
        return np.zeros((0, 16, 96), np.float16)
    return np.load(p, mmap_mode="r")


def acav():
    parts = [np.memmap(f, dtype="<f2", mode="r").reshape(-1, 16, 96) for f in sorted(NEG.glob("acav-slice-*.f16"))]
    return np.concatenate(parts)  # into RAM, ~4.6 GB


def stream_windows(feat):
    """(T, 96) continuous embeddings -> (T-15, 16, 96) windows (a view)."""
    from numpy.lib.stride_tricks import sliding_window_view
    return sliding_window_view(feat, (16, 96))[:, 0]


def count_detections(scores, thr):
    above = scores >= thr
    return int(np.sum(above[1:] & ~above[:-1]) + (above[0] if len(above) else 0))


@torch.no_grad()
def predict(model, X, bs=8192, dev="cuda"):
    out = []
    for i in range(0, len(X), bs):
        out.append(torch.sigmoid(model(torch.from_numpy(np.asarray(X[i:i + bs], np.float32)).to(dev))).cpu().numpy())
    return np.concatenate(out) if out else np.zeros(0)


def export(model, out):
    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    t = {"head.in.w": sd["inp.weight"], "head.in.b": sd["inp.bias"],
         "head.in.ln.g": sd["ln.weight"], "head.in.ln.b": sd["ln.bias"],
         "head.out.w": sd["out.weight"], "head.out.b": sd["out.bias"]}
    for i in range(len(model.blocks)):
        t[f"head.block.{i}.w"] = sd[f"blocks.{i}.weight"]
        t[f"head.block.{i}.b"] = sd[f"blocks.{i}.bias"]
        t[f"head.block.{i}.ln.g"] = sd[f"blns.{i}.weight"]
        t[f"head.block.{i}.ln.b"] = sd[f"blns.{i}.bias"]
    tensors.write(out / "hey-straylight.slt", t)

    class WithSigmoid(nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            return torch.sigmoid(self.m(x)).unsqueeze(-1)

    m = WithSigmoid(model).cpu().eval()
    torch.onnx.export(m, torch.zeros(1, 16, 96), out / "hey-straylight.onnx", input_names=["input"],
                      output_names=["score"], dynamic_axes={"input": {0: "batch"}}, opset_version=13,
                      dynamo=False)
    model.cuda()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--steps", type=int, default=40000)
    ap.add_argument("--dim", type=int, default=64)
    ap.add_argument("--blocks", type=int, default=1)
    ap.add_argument("--max-neg-weight", type=float, default=1500)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--dropout", type=float, default=0.0)
    ap.add_argument("--no-acav", action="store_true",
                    help="train without the ACAV100M features (CC BY-NC-SA); --extra-neg takes their place")
    ap.add_argument("--extra-neg", nargs="*", default=[],
                    help="more general negatives from work/feat (e.g. bg-speech-train)")
    ap.add_argument("--weight-decay", type=float, default=0.0)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    torch.manual_seed(a.seed)
    dev = "cuda"

    def split(X):
        idx = rng.permutation(len(X))
        nv = len(X) // 20
        return np.asarray(X[np.sort(idx[nv:])]), np.asarray(X[np.sort(idx[:nv])])

    pp_tr, pp_va = split(load("piper-pos-train"))
    mp_tr, mp_va = split(load("magpie-pos-train", required=False))
    near = [np.asarray(load(n, required=False)) for n in
            ["piper-neg-train", "piper-partial-train", "magpie-neg-train", "magpie-partial-train"]]
    near = np.concatenate([x for x in near if len(x)])
    bg = np.asarray(load("bg-train"))
    general = [np.asarray(load(n)) for n in a.extra_neg]
    if not a.no_acav:
        print("loading ACAV100M slices", flush=True)
        general.append(acav())
    ac = np.concatenate(general) if len(general) > 1 else general[0]
    fpv = np.load(NEG / "validation_set_features.npy")
    fpv_w = stream_windows(fpv)
    fpv_hours = len(fpv) * 0.08 / 3600
    print(f"pos piper {len(pp_tr)} magpie {len(mp_tr)}; near {len(near)}; bg {len(bg)}; general {len(ac)}; "
          f"fp-val {fpv_hours:.1f} h", flush=True)

    g = lambda x: torch.from_numpy(np.ascontiguousarray(x)).to(dev)  # noqa: E731
    pp_g, mp_g, near_g, bg_g = g(pp_tr), g(mp_tr), g(near), g(bg)
    ac_t = torch.from_numpy(ac)  # stays in host memory
    n_pp, n_mp, n_near, n_bg, n_ac = 192, 64, 192, 64, 1536

    model = Head(a.dim, a.blocks, dropout=a.dropout).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=a.weight_decay)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=a.steps, pct_start=0.05)
    bce = nn.BCEWithLogitsLoss(reduction="none")
    best = None
    hist = open(out / "history.tsv", "w")
    hist.write("step\tneg_weight\tloss\tval_recall\tval_recall_magpie\tfp_per_hour\n")
    vpos = np.concatenate([pp_va, mp_va])
    for step in range(1, a.steps + 1):
        model.train()
        w = 1 + (a.max_neg_weight - 1) * min(1.0, step / (a.steps / 2))
        ri = lambda n, m: torch.randint(0, n, (m,), device=dev)  # noqa: E731
        parts = [pp_g[ri(len(pp_g), n_pp)]]
        if len(mp_g):
            parts.append(mp_g[ri(len(mp_g), n_mp)])
        npos = sum(len(p) for p in parts)
        parts += [near_g[ri(len(near_g), n_near)], bg_g[ri(len(bg_g), n_bg)],
                  ac_t[torch.randint(0, len(ac_t), (n_ac,))].to(dev, non_blocking=True)]
        x = torch.cat(parts).float()
        y = torch.zeros(len(x), device=dev)
        y[:npos] = 1
        # Small feature noise, as cheap augmentation.
        x = x + 0.02 * torch.randn_like(x)
        wt = torch.where(y > 0, torch.ones_like(y), torch.full_like(y, w))
        loss = (bce(model(x), y) * wt).sum() / wt.sum()
        opt.zero_grad()
        loss.backward()
        opt.step()
        sched.step()
        if step % 500 == 0 or step == a.steps:
            model.eval()
            rec = float((predict(model, vpos) >= 0.5).mean())
            rec_m = float((predict(model, mp_va) >= 0.5).mean()) if len(mp_va) else float("nan")
            fp = count_detections(predict(model, fpv_w), 0.5) / fpv_hours
            hist.write(f"{step}\t{w:.0f}\t{loss.item():.4f}\t{rec:.4f}\t{rec_m:.4f}\t{fp:.3f}\n")
            hist.flush()
            print(f"step {step} w {w:.0f} loss {loss.item():.4f} recall {rec:.3f} (magpie {rec_m:.3f}) "
                  f"fp/h {fp:.2f}", flush=True)
            if step % 2500 == 0:
                torch.save({"state": model.state_dict(), "dim": a.dim, "blocks": a.blocks, "step": step},
                           out / f"ckpt-{step}.pt")
            ok = fp <= 0.5
            key = (ok, rec if ok else -fp)
            if step >= a.steps // 4 and (best is None or key > best[0]):
                best = (key, step, {k: v.clone() for k, v in model.state_dict().items()})
    model.load_state_dict(best[2])
    print(f"kept step {best[1]}: {best[0]}", flush=True)
    torch.save({"state": best[2], "dim": a.dim, "blocks": a.blocks, "step": best[1]}, out / "model.pt")
    export(model, out)


if __name__ == "__main__":
    main()
