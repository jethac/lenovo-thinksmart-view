#!/usr/bin/env python3
"""Export a narrow Kokoro student as one ONNX graph with Kokoro's interface,
for straylight-listen's `paradee:NAME` engine and for ncnn (pnnx) later:

    inputs   input_ids [1, T] int64 (a 0 pad at each end), style [1, 256]
             (the voice's style row for T - 2 tokens), speed [1]
    outputs  waveform [S] at 24 kHz, durations [T] (frames of 600 samples)

The text side is Kokoro-82M v1.0's own (weights from KOKORO_DIR), the
decoder the narrow one from train_narrow.py; weight norm is folded in. The
generator's STFT is Paradee's ConvSTFT (conv1d / conv_transpose1d with
fixed DFT bases: matches torch.stft / istft, which the decoder was trained
with, unlike Kokoro's own ONNX STFT). Also writes the voice's style pack
(voice.bin: 510 x 256 little-endian float32, as onnx-community's voices)
and checks the graph against PyTorch on a few held-out rows.

    export_narrow.py WIDTH CKPT OUT_DIR      (in a voice's working directory, PARADEE_VOICE set)
"""
import glob, os, sys, time, warnings
warnings.filterwarnings("ignore")
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
sys.path.insert(0, "scripts")
from narrow import StyledDecoder, ConvSTFT
from teacher_shim import KPipeline, voice_pack
from torch.nn.utils import remove_weight_norm
from torch.nn.utils.parametrize import is_parametrized, remove_parametrizations

width, ckpt, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)


def strip(m):
    for x in m.modules():
        try:
            remove_weight_norm(x)
        except Exception:
            pass
        if is_parametrized(x, "weight"):
            try:
                remove_parametrizations(x, "weight", leave_parametrized=True)
            except Exception:
                pass


class Narrow(nn.Module):
    def __init__(self, km):
        super().__init__(); self.km = km

    def forward(self, input_ids, style, speed):
        km = self.km; T = input_ids.shape[1]
        L = torch.full((1,), T, dtype=torch.long)
        mask = torch.zeros(1, T, dtype=torch.bool)
        d_en = km.bert_encoder(km.bert(input_ids, attention_mask=torch.ones_like(input_ids))).transpose(-1, -2)
        s = style[:, 128:]
        d = km.predictor.text_encoder(d_en, s, L, mask)
        x, _ = km.predictor.lstm(d)
        dur = torch.sigmoid(km.predictor.duration_proj(x)).sum(-1)[0] / speed
        n = torch.clamp(torch.round(dur), min=1).long()
        end = torch.cumsum(n, 0); start = end - n; f = torch.arange(end[-1])[None]
        aln = ((f >= start[:, None]) & (f < end[:, None])).float()[None]
        F0, N = km.predictor.F0Ntrain(d.transpose(-1, -2) @ aln, s)
        asr = km.text_encoder(input_ids, L, mask) @ aln
        return km.decoder(asr, F0, N, style[:, :128]).reshape(-1), n.float()


km = KPipeline(device="cpu").model.eval()
dec = StyledDecoder(width).eval()
if ckpt != "random":  # "random": untrained weights, for speed measurements only
    dec.load_state_dict(torch.load(ckpt, map_location="cpu")["model"])
if os.environ.get("BERT_HIDDEN"):  # speed measurements only: a narrower PL-BERT, untrained
    from transformers import AlbertConfig
    from kokoro.modules import CustomAlbert
    h = int(os.environ["BERT_HIDDEN"])
    km.bert = CustomAlbert(AlbertConfig(vocab_size=178, hidden_size=h, num_attention_heads=max(1, h // 64), intermediate_size=4 * h,
                                        num_hidden_layers=12, max_position_embeddings=512, embedding_size=128)).eval()
    km.bert_encoder = torch.nn.Linear(h, km.bert_encoder.out_features)
strip(km); strip(dec)
dec.generator.stft = ConvSTFT(dec.generator.stft.filter_length, dec.generator.stft.hop_length)
km.decoder = dec
m = Narrow(km).eval()
pack = voice_pack(os.environ.get("PARADEE_VOICE", "af_heart")).float()
pack.reshape(-1, 256).numpy().astype("<f4").tofile(os.path.join(out, "voice.bin"))
shards = sorted(glob.glob("data/teacher/shard_*.pt"))
if shards:
    held = torch.load(shards[0])[:4]
else:  # no teacher corpus here: check on the evaluation lines (no teacher durations to compare)
    import json
    voc = json.load(open(os.path.join(os.environ.get("KOKORO_DIR", "/w/downloads/hexgrad"), "config.json")))["vocab"]
    lang = os.path.basename(os.getcwd())
    held = []
    for l in list(open(f"/w/data/eval-{lang}.phon.tsv", encoding="utf-8"))[:4]:
        ids = torch.LongTensor([0] + [voc[c] for c in l.split("\t")[2] if c in voc] + [0])
        held.append({"ids": ids, "pred_dur": torch.zeros(1, dtype=torch.long)})
ids = held[1]["ids"][None]
st = pack[ids.shape[1] - 3].reshape(1, 256)
path = os.path.join(out, "model.onnx")
with torch.no_grad():
    torch.onnx.export(m, (ids, st, torch.ones(1)), path, input_names=["input_ids", "style", "speed"],
                      output_names=["waveform", "durations"], opset_version=17, dynamo=False,
                      dynamic_axes={"input_ids": {1: "tokens"}, "waveform": {0: "samples"}, "durations": {0: "tokens"}})
print(f"exported {path}: {os.path.getsize(path) / 1e6:.1f} MB, decoder {sum(p.numel() for p in dec.parameters()) / 1e6:.2f}M, "
      f"all {sum(p.numel() for p in m.parameters()) / 1e6:.2f}M params", flush=True)

import onnxruntime as ort
so = ort.SessionOptions(); so.intra_op_num_threads = 4
sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
tot = secs = 0.0
for r in held:
    i = r["ids"][None]; s_ = pack[i.shape[1] - 3].reshape(1, 256)
    t = time.perf_counter()
    y, d = sess.run(None, {"input_ids": i.numpy(), "style": s_.numpy(), "speed": np.ones(1, np.float32)})
    tot += time.perf_counter() - t; secs += len(y) / 24000
    with torch.no_grad():
        yt, dt = m(i, s_, torch.ones(1))
    print(f"len onnx {len(y)} torch {len(yt)}, durations equal {np.array_equal(d, dt.numpy())}, teacher frames {int(r['pred_dur'].sum())} vs {int(d.sum())}")
print(f"ORT 4 threads (this CPU): RTF {tot / secs:.3f}")
