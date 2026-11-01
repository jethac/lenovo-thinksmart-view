#!/usr/bin/env python3
"""Compare the GPU decoder's outputs with PyTorch and ONNX Runtime fp32.

    kokoro-compare.py OUT_DIR TORCH.npz BOUNDARY.npz [--wav OUT.wav]

Per stage: SNR (dB) and max error against the PyTorch dumps (kokoro-ref.py
torch). Waveform: SNR against ORT fp32 and PyTorch, plus spectral metrics
that ignore phase (STFT magnitude SNR, log-spectral distance), since the
source's near-zero bins have arbitrary phase in any implementation (ORT and
PyTorch differ there too).
"""
import glob, os, sys
import numpy as np


def snr(ref, x):
    e = x - ref
    return 10 * np.log10((ref ** 2).sum() / max((e ** 2).sum(), 1e-30))


def mag(w, n=1024, hop=256):
    win = np.hanning(n).astype(np.float32)
    fr = np.lib.stride_tricks.sliding_window_view(np.pad(w, n // 2), n)[::hop] * win
    return np.abs(np.fft.rfft(fr, axis=1))


def spec_metrics(ref, x):
    a, b = mag(ref), mag(x)
    msnr = snr(a, b)
    la, lb = 20 * np.log10(a + 1e-5), 20 * np.log10(b + 1e-5)
    keep = la.max(axis=1) > la.max() - 60  # frames within 60 dB of the loudest
    lsd = np.sqrt(((la - lb) ** 2).mean(axis=1))[keep].mean()
    return msnr, lsd


def main():
    out, tz, bz = sys.argv[1:4]
    t, b = np.load(tz), np.load(bz)
    ref = {
        'encode': t['encode'][0], 'decode.0': t['decode_0'][0], 'decode.1': t['decode_1'][0], 'decode.2': t['decode_2'][0],
        'decode.3': t['decode_3'][0], 'noise_res.0': t['generator_noise_res_0'][0],
        'stage1': (t['generator_resblocks_0'] + t['generator_resblocks_1'] + t['generator_resblocks_2'])[0] / 3,
        'noise_res.1': t['generator_noise_res_1'][0],
        'stage2': (t['generator_resblocks_3'] + t['generator_resblocks_4'] + t['generator_resblocks_5'])[0] / 3,
        'conv_post': t['generator_conv_post'][0], 'har': t['har'][0], 'noise_conv.0': t['generator_noise_convs_0'][0],
    }
    print('%-12s %-14s %8s %10s %10s' % ('stage', 'shape', 'SNR dB', 'max err', 'max |ref|'))
    for name in ['har', 'noise_conv.0', 'encode', 'decode.0', 'decode.1', 'decode.2', 'decode.3', 'noise_res.0', 'stage1',
                 'noise_res.1', 'stage2', 'conv_post']:
        fs = glob.glob(os.path.join(out, name + '.*.f32'))
        if not fs:
            continue
        C, T = map(int, fs[0].rsplit('.', 2)[1].split('x'))
        g = np.fromfile(fs[0], '<f4').reshape(C, T)
        r = ref[name]
        g = g[:r.shape[0], :r.shape[1]]
        extra = ''
        if name == 'har':
            extra = '  (magnitudes: %.1f dB)' % snr(r[:11], g[:11])
        if name == 'conv_post':
            extra = '  (log-magnitude channels: %.1f dB)' % snr(r[:11], g[:11])
        print('%-12s %-14s %8.1f %10.3g %10.3g%s' % (name, '%dx%d' % r.shape, snr(r, g), np.abs(g - r).max(),
                                                      np.abs(r).max(), extra))
    a = np.fromfile(os.path.join(out, 'audio.f32'), '<f4')
    for nm, w in (('ORT fp32', b['wav'].reshape(-1)), ('PyTorch', t['wav'].reshape(-1))):
        n = min(len(w), len(a))
        ms, lsd = spec_metrics(w[:n], a[:n])
        print('waveform vs %-9s SNR %5.1f dB  |STFT| SNR %5.1f dB  LSD %.2f dB  (len %d / %d)' % (nm, snr(w[:n], a[:n]), ms, lsd, len(a), len(w)))
    w, tw = b['wav'].reshape(-1), t['wav'].reshape(-1)
    ms, lsd = spec_metrics(w, tw)
    print('reference: PyTorch vs ORT  SNR %5.1f dB  |STFT| SNR %5.1f dB  LSD %.2f dB' % (snr(w, tw), ms, lsd))
    if '--wav' in sys.argv:
        import wave
        p = sys.argv[sys.argv.index('--wav') + 1]
        with wave.open(p, 'wb') as f:
            f.setnchannels(1); f.setsampwidth(2); f.setframerate(24000)
            f.writeframes((np.clip(a, -1, 1) * 32767).astype('<i2').tobytes())


if __name__ == '__main__':
    main()
