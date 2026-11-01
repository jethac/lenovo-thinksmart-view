#!/usr/bin/env python3
"""Reference data for the GPU decoder (laptop).

    kokoro-ref.py boundary OUT.npz PHONEMES VOICE.bin   ORT fp32: decoder inputs and the waveform
    kokoro-ref.py torch IN.npz OUT.npz                  PyTorch decoder on the same inputs, per-layer dumps
    kokoro-ref.py weights OUT.bin                       decoder weights (weight norm folded), fp32, with OUT.bin.json
    kokoro-ref.py export OUT.kdec                       the same for the GPU decoder: conv weights fp16, the rest fp32
    kokoro-ref.py inputs IN.npz DIR                     raw decoder inputs (asr, f0, n, style) for kokoro-gpu-check

The onnx-community export has no random ops: the sine source's initial
phases and its additive noise are zero, so the decoder is deterministic and
PyTorch is run with torch.rand / randn_like returning zeros to match it.
"""
import json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TTS = os.path.join(HERE, '..', '..', 'tts', 'downloads', 'kokoro')
ONNX = os.path.join(TTS, 'onnx-community', 'onnx', 'model.onnx')
HEX = os.path.join(TTS, 'hexgrad')
ASR, F0, NN = '/encoder/MatMul_1_output_0', '/encoder/Reshape_output_0', '/encoder/Reshape_1_output_0'
HAR, SRC = '/decoder/decoder/generator/Concat_3_output_0', '/decoder/decoder/generator/m_source/l_tanh/Tanh_output_0'


def vocab():
    return json.load(open(os.path.join(HEX, 'config.json')))['vocab']


def boundary(out, ps, voice):
    import onnx, onnxruntime as ort
    m = onnx.load(ONNX)
    for n in (ASR, F0, NN, HAR, SRC):
        m.graph.output.append(onnx.helper.make_tensor_value_info(n, onnx.TensorProto.FLOAT, None))
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    s = ort.InferenceSession(m.SerializeToString(), so, providers=['CPUExecutionProvider'])
    v = vocab()
    ids = [0] + [v[c] for c in ps if c in v] + [0]
    pack = np.fromfile(voice, dtype='<f4').reshape(-1, 256)
    style = pack[len(ids) - 3][None]
    wav, asr, f0, nn, har, src = s.run(None, {'input_ids': np.array([ids], np.int64), 'style': style,
                                    'speed': np.array([1.0], np.float32)})
    np.savez(out, ids=np.array(ids), style=style, asr=asr, f0=f0, n=nn, wav=wav, har=har, src=src)
    print(out, 'tokens', len(ids), 'asr', asr.shape, 'f0', f0.shape, 'wav', wav.shape)


def kmodel():
    import torch
    from kokoro import KModel
    k = KModel(repo_id='hexgrad/Kokoro-82M', config=os.path.join(HEX, 'config.json'),
               model=os.path.join(HEX, 'kokoro-v1_0.pth')).eval()
    for mod in k.decoder.modules():
        try:
            torch.nn.utils.remove_weight_norm(mod)
        except (ValueError, AttributeError):
            pass
    return k


def torch_run(inp, out):
    import torch
    d = np.load(inp)
    k = kmodel()
    dec = k.decoder
    acts = {}
    def hook(name):
        def f(m, i, o):
            acts[name] = (o[0] if isinstance(o, tuple) else o).detach().numpy().astype(np.float32)
        return f
    for name, mod in dec.named_modules():
        if name and name.count('.') <= 2 and 'm_source' not in name and 'stft' not in name:
            mod.register_forward_hook(hook(name))
    zr, zn = torch.rand, torch.randn_like
    torch.rand = lambda *a, **kw: torch.zeros(*a, **{x: y for x, y in kw.items() if x != 'generator'})
    torch.randn_like = lambda x, *a, **kw: torch.zeros_like(x)
    # the harmonic source spectrum the generator works from (input of noise_convs.0)
    dec.generator.noise_convs[0].register_forward_hook(lambda m, i, o: acts.__setitem__('har', i[0].numpy()))
    # the generator's last tensor before the iSTFT (conv_post output)
    with torch.no_grad():
        wav = dec(torch.from_numpy(d['asr']), torch.from_numpy(d['f0']), torch.from_numpy(d['n']),
                  torch.from_numpy(d['style'][:, :128])).squeeze().numpy()
    torch.rand, torch.randn_like = zr, zn
    ref = d['wav'].reshape(-1)
    n = min(len(ref), len(wav))
    err = wav[:n] - ref[:n]
    print('torch vs ORT fp32: len %d/%d SNR %.1f dB, max err %.2e' % (len(wav), len(ref),
          10 * np.log10((ref[:n] ** 2).sum() / max((err ** 2).sum(), 1e-30)), np.abs(err).max()))
    np.savez(out, wav=wav, **{k.replace('.', '_'): v for k, v in acts.items()})
    for k_, v in acts.items():
        print(' ', k_, v.shape)


def weights(out):
    k = kmodel()
    sd = {n: p.detach().numpy().astype(np.float32) for n, p in k.decoder.state_dict().items()}
    man, off = [], 0
    with open(out, 'wb') as f:
        for n, a in sd.items():
            if 'running' in n or 'num_batches' in n:
                continue
            f.write(np.ascontiguousarray(a).tobytes())
            man.append({'name': n, 'shape': list(a.shape), 'offset': off})
            off += a.size * 4
    json.dump(man, open(out + '.json', 'w'), indent=0)
    print(out, len(man), 'tensors', off / 1e6, 'MB fp32')


def export(out):
    """KDEC1 file: magic, u32 count, then per tensor: u16 name length, name,
    u8 dtype (0 f32, 1 f16), u8 ndim, u32 dims, u32 padding to 4 bytes, data."""
    import struct
    k = kmodel()
    sd = {n: p.detach().numpy().astype(np.float32) for n, p in k.decoder.state_dict().items()}
    with open(out, 'wb') as f:
        items = [(n, a) for n, a in sd.items() if 'running' not in n and 'num_batches' not in n]
        f.write(b'KDEC1\0\0\0' + struct.pack('<I', len(items)))
        tot = 0
        for n, a in items:
            h = a.ndim == 3 and n.endswith('weight') and a.size > 64
            b = n.encode()
            hdr = struct.pack('<H', len(b)) + b + struct.pack('<BB', int(h), a.ndim) + struct.pack('<%dI' % a.ndim, *a.shape)
            f.write(hdr + b'\0' * ((-len(hdr) - f.tell()) % 4))
            d = a.astype(np.float16 if h else np.float32).tobytes()
            f.write(d + b'\0' * (-len(d) % 4))
            tot += len(d)
    print(out, len(items), 'tensors', tot / 1e6, 'MB')


def inputs(inp, d):
    os.makedirs(d, exist_ok=True)
    z = np.load(inp)
    T = z['asr'].shape[2]
    z['asr'][0].astype('<f4').tofile(os.path.join(d, 'asr.f32'))
    z['f0'][0].astype('<f4').tofile(os.path.join(d, 'f0.f32'))
    z['n'][0].astype('<f4').tofile(os.path.join(d, 'n.f32'))
    z['style'][0, :128].astype('<f4').tofile(os.path.join(d, 'style.f32'))
    open(os.path.join(d, 'T'), 'w').write('%d\n' % T)
    print(d, 'T', T)


if __name__ == '__main__':
    c = sys.argv[1]
    if c == 'boundary': boundary(*sys.argv[2:5])
    elif c == 'torch': torch_run(*sys.argv[2:4])
    elif c == 'weights': weights(sys.argv[2])
    elif c == 'export': export(sys.argv[2])
    elif c == 'inputs': inputs(sys.argv[2], sys.argv[3])
