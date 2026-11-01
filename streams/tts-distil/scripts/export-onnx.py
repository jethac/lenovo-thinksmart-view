#!/usr/bin/env python3
"""Export a distilled voice for straylight-listen's Matcha engine
(listen/src/tts/matcha.rs), in the layout of sherpa-onnx's icefall Matcha
models:

    model.onnx  inputs x [1, N] int64, x_length [1] int64, noise_scale [1],
                length_scale [1]; outputs mel [1, 80, T] (log mel, as the
                vocoder takes it) and durations [1, N] (frames per input
                token: the ceil'd durations times length_scale)
    vocos.onnx  input mels [1, 80, T]; outputs mag, x, y [1, 513, T]
                (magnitude, cos and sin of the phase; n_fft 1024, hop 256)
    tokens.txt  symbol and ID per line

    export-onnx.py MATCHA.ckpt VOCOS_G.pt TOKENS.txt OUT_DIR [--steps 3]
"""
import argparse, os, shutil, sys
import torch

sys.path.insert(0, "/w/src/Matcha-TTS")
sys.path.insert(0, "/w/downloads/vocos")
from matcha.models.matcha_tts import MatchaTTS  # noqa: E402
from matcha.utils.model import sequence_mask, generate_path, fix_len_compatibility, denormalize  # noqa: E402
from vocos.models import VocosBackbone  # noqa: E402
from vocos.heads import ISTFTHead  # noqa: E402


class AM(torch.nn.Module):
    def __init__(self, m, steps):
        super().__init__()
        self.m, self.steps = m, steps

    def forward(self, x, x_length, noise_scale, length_scale):
        m = self.m
        mu_x, logw, x_mask = m.encoder(x, x_length, None)
        w = torch.exp(logw) * x_mask
        w_ceil = torch.ceil(w) * length_scale
        y_lengths = torch.clamp_min(torch.sum(w_ceil, [1, 2]), 1).long()
        y_max_length = y_lengths.max()
        y_max_length_ = fix_len_compatibility(y_max_length)
        y_mask = sequence_mask(y_lengths, y_max_length_).unsqueeze(1).to(x_mask.dtype)
        attn_mask = x_mask.unsqueeze(-1) * y_mask.unsqueeze(2)
        attn = generate_path(w_ceil.squeeze(1), attn_mask.squeeze(1)).unsqueeze(1)
        mu_y = torch.matmul(attn.squeeze(1).transpose(1, 2), mu_x.transpose(1, 2)).transpose(1, 2)
        dec = m.decoder(mu_y, y_mask, self.steps, noise_scale, None)
        dec = dec[:, :, :y_max_length]
        return denormalize(dec, m.mel_mean, m.mel_std), w_ceil.squeeze(1)


class Voc(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.backbone = VocosBackbone(input_channels=80, dim=512, intermediate_dim=1536, num_layers=8)
        self.head = ISTFTHead(dim=512, n_fft=1024, hop_length=256, padding="center")

    def forward(self, mels):
        h = self.head.out(self.backbone(mels)).transpose(1, 2)
        mag, p = h.chunk(2, dim=1)
        mag = torch.clip(torch.exp(mag), max=1e2)
        return mag, torch.cos(p), torch.sin(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpt")
    ap.add_argument("vocos")
    ap.add_argument("tokens")
    ap.add_argument("out")
    ap.add_argument("--steps", type=int, default=3)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    m = MatchaTTS.load_from_checkpoint(a.ckpt, map_location="cpu", weights_only=False).eval()
    am = AM(m, a.steps).eval()
    n = 60
    x = torch.randint(1, 170, (1, n), dtype=torch.long)
    inp = (x, torch.LongTensor([n]), torch.tensor([0.667]), torch.tensor([1.0]))
    with torch.no_grad():
        torch.onnx.export(am, inp, os.path.join(a.out, "model.onnx"), dynamo=False, opset_version=17,
                          input_names=["x", "x_length", "noise_scale", "length_scale"],
                          output_names=["mel", "durations"],
                          dynamic_axes={"x": {1: "N"}, "mel": {2: "T"}, "durations": {1: "N"}})
    v = Voc().eval()
    sd = torch.load(a.vocos, map_location="cpu")
    v.load_state_dict(sd)
    with torch.no_grad():
        torch.onnx.export(v, (torch.randn(1, 80, 100),), os.path.join(a.out, "vocos.onnx"), dynamo=False,
                          opset_version=17, input_names=["mels"], output_names=["mag", "x", "y"],
                          dynamic_axes={"mels": {2: "T"}, "mag": {2: "T"}, "x": {2: "T"}, "y": {2: "T"}})
    shutil.copy(a.tokens, os.path.join(a.out, "tokens.txt"))
    print("params: matcha", sum(p.numel() for p in m.parameters()), "vocos", sum(p.numel() for p in v.parameters()))


main()
