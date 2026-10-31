"""Multiply-accumulate count of the NanoCodec decoder per second of audio, from the
GGUF's convolution shapes and the decoder's upsampling rates.

    codec-flops.py nanocodec.decoder.gguf
"""
import sys
import gguf
r = gguf.GGUFReader(sys.argv[1])
f = {k: v.contents() for k, v in r.fields.items() if not k.startswith("GGUF")}
rates = f["nano_codec.decoder.up_sample_rates"]
fps = f["nano_codec.sample_rate"] / f["nano_codec.samples_per_frame"]
w = {t.name: [int(x) for x in t.shape] for t in r.tensors if len(t.shape) == 3 and t.shape[0] > 1 and t.name.endswith("w")}
total = 0.0
def add(name, macs_per_s):
    global total; total += macs_per_s
    return macs_per_s
rate = fps
per = {}
for n, (K, a, b) in w.items():
    parts = n.split(".")
    if n.startswith("dec.pre"):
        per[n] = add(n, K * a * b * fps)           # [K, Cin, Cout]
    elif n.startswith("dec.up"):
        i = int(parts[2]); out_rate = fps
        for j in range(i + 1): out_rate *= rates[j]
        per[n] = add(n, K * a * b * out_rate / rates[i])   # [K, Cout, Cin] at the input rate, K taps each
    elif n.startswith("dec.res"):
        i = int(parts[2]); out_rate = fps
        for j in range(i + 1): out_rate *= rates[j]
        per[n] = add(n, K * a * b * out_rate)
    elif n.startswith("dec.post"):
        per[n] = add(n, K * a * b * f["nano_codec.sample_rate"])
print(f"{len(w)} convolutions, {2*total/1e9:.1f} GFLOP per second of audio ({total/1e9:.1f} G multiply-adds)")
for k in sorted({".".join(n.split(".")[:3]) for n in per}):
    print(f"  {k:12s} {2*sum(v for n, v in per.items() if n.startswith(k + '.') or n == k)/1e9:6.2f} GFLOP/s")
