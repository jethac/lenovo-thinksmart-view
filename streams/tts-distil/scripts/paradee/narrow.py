"""The narrow Kokoro student: Kokoro-82M's own text side (PL-BERT, prosody
predictor, text encoder: frozen, the teacher's weights) with Kokoro's
iSTFTNet decoder at reduced widths, conditioned on the teacher's style
vector (the decoder's 128-value half of the voice's style row), so each
voice ships with exactly its teacher's style pack.

Width presets, as a fraction of the teacher's decoder (AdaIN width 1024,
generator upsample_initial_channel 512). Everything else is the teacher's:
upsample rates [10, 6], kernels [20, 12], resblock kernels [3, 7, 11] with
dilations [1, 3, 5], post n_fft 20, hop 5, style_dim 128.

    python narrow.py         prints parameters and measured GFLOP per second
                             of audio for each preset and the teacher, and the
                             text side's FLOPs per phoneme
"""
import torch, torch.nn as nn, torch.nn.functional as F
from student_decoder import StudentDecoder, DEC_PRESETS

WIDTHS = {"x25": (256, 128), "x35": (352, 176), "x40": (416, 208), "x50": (512, 256), "teacher": (1024, 512)}
for k, (w, u) in WIDTHS.items():
    DEC_PRESETS.setdefault("n" + k, (w, u, [3, 7, 11]))
# with two resblock kernels per stage ([3, 7], as Kokoro-7M-Distill), a third fewer resblocks
for k in ("x20", "x25", "x30", "x35"):
    w, u = {"x20": (192, 96), "x30": (320, 160)}.get(k) or WIDTHS[k]
    DEC_PRESETS.setdefault(f"n{k}k2", (w, u, [3, 7]))


class StyledDecoder(StudentDecoder):
    """Kokoro's Decoder at the preset's widths; forward takes the style (decoder half, [B, 128])."""
    def __init__(self, width="x35", **kw):
        super().__init__("n" + width, style_dim=128, **kw)
        del self.style

    def forward(self, asr, F0_curve, N, s):
        return super(StudentDecoder, self).forward(asr, F0_curve, N, s)


class ConvSTFT(nn.Module):
    """From Paradee's export_paradee.py (Apache-2.0): torch.stft / istft (hann, centred, reflect) as convolutions."""
    def __init__(self, n, hop):
        super().__init__(); self.n, self.hop = n, hop; w = torch.hann_window(n); k = torch.arange(n // 2 + 1).float()[:, None]
        ang = 2 * torch.pi * k * torch.arange(n).float() / n
        re, im = torch.cos(ang) * w, -torch.sin(ang) * w; im[0] = 0; im[-1] = 0
        self.register_buffer("fwd", torch.cat([re, im])[:, None], persistent=False)
        c = torch.full((n // 2 + 1, 1), 2.0); c[0] = c[-1] = 1
        self.register_buffer("inv", (torch.cat([torch.cos(ang) * c, -torch.sin(ang) * c]) / n * w)[:, None], persistent=False)
        self.register_buffer("w2", (w ** 2)[None, None], persistent=False)

    def transform(self, x):
        y = F.conv1d(F.pad(x[:, None], (self.n // 2, self.n // 2), mode="reflect"), self.fwd, stride=self.hop); K = self.n // 2 + 1
        re, im = y[:, :K], y[:, K:]
        ph = torch.where((im == 0) & (re < 0), torch.full_like(re, torch.pi), torch.atan2(im, re))
        return torch.sqrt(re ** 2 + im ** 2), ph

    def inverse(self, mag, phase):
        z = torch.cat([mag * torch.cos(phase), mag * torch.sin(phase)], 1)
        y = F.conv_transpose1d(z, self.inv, stride=self.hop)[:, 0]
        env = F.conv_transpose1d(torch.ones(1, 1, mag.shape[-1], device=mag.device, dtype=mag.dtype), self.w2, stride=self.hop)[:, 0]
        return (y / env.clamp_min(1e-8))[:, self.n // 2: -(self.n // 2)][:, None]



def conv_stft(m):
    """Use ConvSTFT (the exported graph's own STFT) for the generator, on the
    model's device: training then computes exactly what inference does,
    including the phase at the DC and Nyquist bins (pi where the real part is
    negative), with no CPU round trip."""
    g = m.generator
    dev = next(m.parameters()).device
    g.stft = ConvSTFT(g.stft.filter_length, g.stft.hop_length).to(dev)
    return m


def gflop_per_s(m, T=174):
    from torch.utils.flop_counter import FlopCounterMode
    asr = torch.randn(1, 512, T); F0 = torch.rand(1, 2 * T) * 200 + 80; N = torch.randn(1, 2 * T); s = torch.randn(1, 128)
    fc = FlopCounterMode(display=False)
    with fc, torch.no_grad():
        y = m(asr, F0, N, s)
    return fc.get_total_flops() / (y.shape[-1] / 24000) / 1e9


if __name__ == "__main__":
    import os, sys
    np_ = lambda m: sum(x.numel() for x in m.parameters()) / 1e6
    print(f"{'width':8s} {'params':>8s} {'GFLOP/audio-s':>14s}")
    for k in list(WIDTHS) + ["x20k2", "x25k2", "x30k2", "x35k2"]:
        m = StyledDecoder(k).eval()
        print(f"{k:8s} {np_(m):7.2f}M {gflop_per_s(m):14.2f}", flush=True)
    # the teacher's text side, per phoneme (needs KOKORO_DIR)
    if os.environ.get("KOKORO_DIR"):
        from torch.utils.flop_counter import FlopCounterMode
        from teacher_shim import KPipeline, voice_pack
        km = KPipeline().model
        for n in (50, 200):
            ids = torch.randint(1, 170, (1, n)); L = torch.tensor([n]); mask = torch.zeros(1, n, dtype=torch.bool)
            s = torch.randn(1, 128)
            fc = FlopCounterMode(display=False)
            with fc, torch.no_grad():
                d_en = km.bert_encoder(km.bert(ids, attention_mask=(~mask).int())).transpose(-1, -2)
                d = km.predictor.text_encoder(d_en, s, L, mask); x, _ = km.predictor.lstm(d)
                dur = torch.sigmoid(km.predictor.duration_proj(x)).sum(-1)
                t_en = km.text_encoder(ids, L, mask)
            print(f"text side (bert, predictor's encoder and duration, text encoder): {fc.get_total_flops() / n / 1e6:.1f} MFLOP per phoneme at {n} phonemes (LSTMs not counted by the FLOP counter)")
        fr = 100  # F0/energy curves per frame
        en = torch.randn(1, 640, fr)
        fc = FlopCounterMode(display=False)
        with fc, torch.no_grad():
            km.predictor.F0Ntrain(en, s)
        print(f"F0 and energy predictor: {fc.get_total_flops() / (fr * 600 / 24000) / 1e9:.2f} GFLOP per second of audio")
        p = lambda m: sum(x.numel() for x in m.parameters()) / 1e6
        print(f"teacher params: bert {p(km.bert):.2f}M bert_encoder {p(km.bert_encoder):.2f}M predictor {p(km.predictor):.2f}M text_encoder {p(km.text_encoder):.2f}M decoder {p(km.decoder):.2f}M")
