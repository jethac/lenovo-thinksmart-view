"""Table of device runs from device-tts.sh output (OUTDIR/*.err etc.).

    summarise-device.py OUTDIR [TAG...]

Uses the runtime's final metrics line of the measured request (the warmup request
comes first). Stall = how much silence a listener would hear if playback started
at the first audio and continued as audio arrived: elapsed - time to first audio
- audio length (0 if it kept up).
"""
import os, re, sys
d = sys.argv[1]
tags = sys.argv[2:] or sorted(f[:-4] for f in os.listdir(d) if f.endswith(".err"))
print("| Run | Audio | First audio | Total | RTF | Stall | Text encoder | Decoder step (avg / min) | Codec chunk 186 ms (avg) | Peak RSS |")
print("|---|---|---|---|---|---|---|---|---|---|")
for t in tags:
    txt = open(os.path.join(d, t + ".err"), errors="ignore").read()
    m = [dict(re.findall(r"(\w+)=([\d.]+)", l)) for l in txt.splitlines() if l.startswith("generated ")]
    if not m:
        print(f"| {t} | failed (rc {open(os.path.join(d, t + '.rc')).read().strip()}) |"); continue
    x = {k: float(v) for k, v in m[-1].items()}
    peak = int(open(os.path.join(d, t + ".peak_kb")).read()) / 1024
    audio, el, ttfa = x["e2e_audio_s"], x["e2e_elapsed_s"], x["e2e_ttfa_ms"] / 1000
    stall = max(0.0, el - ttfa - audio)
    print(f"| {t} | {audio:.1f} s | {ttfa:.1f} s | {el:.1f} s | {x['e2e_rtf']:.1f} | {stall:.1f} s | "
          f"{x['encoder_ms']/1000:.1f} s | {x['decoder_itl_avg_ms']:.0f} / {x['decoder_itl_min_ms']:.0f} ms | "
          f"{x['codec_icl_avg_ms']:.0f} ms | {peak:.0f} MiB |")
