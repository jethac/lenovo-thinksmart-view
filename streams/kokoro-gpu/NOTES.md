# kokoro-gpu: Kokoro-82M's decoder on the Adreno 506 (FP16 fragment shaders)

Goal: continuous Kokoro speech on the tablet by running the decoder (AdaIN residual blocks and the iSTFTNet generator, about 51 GFLOP per second of audio) on the GPU, with the text encoder and prosody predictor left on the CPU.

**Status (2026-11-01): parked.** The decoder is complete and correct (verified on the laptop's GPU against PyTorch and ONNX Runtime fp32) and is in straylight-listen as `--tts-backend kokoro-gpu` (straylight-voice `ae32401`, Cargo feature `gpu`), **off by default**: the kernels measured on the Adreno reach only 5–7 GFLOP/s for the convolutions (12.5 for a GEMM shape), so the decoder would run at about 7–8x real time, far worse than the CPU path (RTF 2.9). The faster kernel variants write nothing on the a5xx (finding 2 below), which is the open question for the patched-Mesa stream. Nothing changed on the device.

## Design

### straylight-gpu (straylight-voice `gpu/`, commit `ae32401`)

A small reusable C library (static, `gpu/build.sh aarch64|native`; it `dlopen`s libEGL, so binaries have no link-time Mesa dependency), meant for this decoder and later for the ASR prefill:

- surfaceless EGL + GLES 3.1 context;
- tensors `[C x T]` in RGBA16F (or RGBA32F) 2D array textures: 4 channels per texel; a fragment produces L time steps x G channel groups through L*G render targets that are the layers of one array texture; time wrapped into rows of W steps with an H-step halo (64) duplicated from the neighbours and zero outside [0, T), so a reader picks the row once per fragment and no tap needs a bounds check;
- generated kernels: conv1d (dilated, strided, FP16 multiply-add with FP16 partial sums folded into FP32 every `fold` channel groups, fused bias, up to two residual adds and a scale, optional leaky-ReLU on the input), Q8_0-style int8 weights (RGBA8_SNORM, one scale per 32 input channels, folded once per block) for 1x1 convs / GEMM, transposed conv1d (with Kokoro's reflection pad), instance-norm statistics (two passes, FP32), affine + leaky/snake activation, x2 nearest and depthwise transposed upsampling, iSTFT (FP32, reads back only the audio);
- submission control: every pass is cut into scissor bands of bounded cost, each flushed with a fence, at most 2 in flight; a cancel flag is polled between bands;
- `sg-bench` (kernel timing; every timed run starts from a cleared output, is verified against a double reference on sampled outputs, and a configuration whose warm-up raises the kernel's hangcheck count is not timed), `kokoro-gpu-check` (decoder on raw inputs, per-stage dumps).

### Kokoro decoder (`gpu/src/kokoro.c`)

- Weights: `scripts/kokoro-ref.py export` writes `kokoro-v1.0-decoder.kdec` (weight norm folded; conv weights FP16, AdaIN/norm/alpha/bias FP32): 116 MB on disk, **94 MiB of GPU textures**.
- CPU parts per piece: F0/N stride-2 convs, the sine source (SineGen, l_linear, tanh) and its STFT (n_fft 20, hop 5), the AdaIN gamma/beta from the style vector (all 58 AdaINs): about 30 ms for 5 s of audio.
- The source phase is accumulated in double precision. The ONNX export computes `2*pi*300*cumsum(f0/sr)` in fp32, where the argument reaches 1e5–1e6 rad and an ulp is about 0.06–0.1 rad, so the upper harmonics' phases are partly rounding noise: ONNX Runtime and PyTorch (both fp32, same weights) agree only to 9.8 dB waveform SNR / 4.74 dB log-spectral distance (LSD) on the test line. The export has no random ops (initial phases and noise are zero), and neither has this.
- GPU graph: encode, decode.0–3 (concatenations written in place into 1090-channel tensors), noise_convs/noise_res, ups.0/ups.1, three resblocks per stage with their mean fused into the last conv's epilogue, conv_post (FP32 output), iSTFT. Activations for a 5.3 s piece: 77 MiB (171 MiB total with weights on the laptop run); sized for the longest piece seen.
- Front end: `scripts/kokoro-front-onnx.py` cuts the installed uint8 model at the decoder (outputs asr, F0, N, durations; F0/N dequantised from the uint8 tensors the CPU decoder also uses): 78 MB instead of 177 MB.

### straylight-listen (commit `ae32401`)

- `listen/src/tts/kokoro_gpu.rs`: backend switch, cancel flag, FFI, the front session (ONNX Runtime, same settings as Kokoro's) and the GPU decoder. Cargo feature `gpu` links `out/gpu-<target>/libstraylight_gpu.a` (`listen/build.rs`).
- Hooks: `kokoro.rs` (`Kokoro` holds either the whole CPU model or the GPU decoder; `open` falls back to the CPU model if GL or the files are missing), `mod.rs` (`kokoro_gpu::cancel()` / `uncancel()` beside every `run.terminate()` / `unterminate()`), `main.rs` (`--tts-backend kokoro|kokoro-gpu`; `STRAYLIGHT_TTS_BACKEND=kokoro-gpu` for `--tts-bench`).
- Files expected next to the model: `kokoro-v1.0-uint8-front.onnx`, `kokoro-v1.0-decoder.kdec`.

## Verification (laptop, NVIDIA GLES 3.2; same shaders)

`scripts/kokoro-ref.py` (ORT fp32 boundary tensors, PyTorch per-stage dumps), `scripts/kokoro-compare.py`, test line "Hello! This is a test of the decoder on the GPU, and it should sound the same." (af_heart, 213 frames, 5.33 s):

| Stage | SNR vs PyTorch fp32 |
| --- | ---: |
| encode | 59.4 dB |
| decode.0 / .1 / .2 / .3 | 57.4 / 56.6 / 56.6 / 57.6 dB |
| noise_conv.0 | 57.4 dB |
| noise_res.0, stage 1, noise_res.1, stage 2, conv_post (PyTorch's source injected) | 55.9, 53.5, 59.8, 54.7, 54.4 dB |
| waveform (PyTorch's source injected) | **42.2 dB** (STFT magnitude 45.9 dB, LSD 1.11 dB) |
| waveform, own double-precision source, vs PyTorch | 20.9 dB (LSD 2.14 dB) |
| waveform, own source, vs ORT fp32 | 9.7 dB (LSD 4.84 dB) — the same as PyTorch vs ORT (9.8 dB, 4.74 dB) |

So FP16 storage and FP16 arithmetic with FP32 folds cost nothing measurable (every stage 54–60 dB); the remaining differences are the source's phase noise, which separates the fp32 references from each other by as much.

End to end through `straylight-listen --tts-bench` (14 lines of `tts/cases/kokoro-lines.tsv`, af_heart): the GPU backend against the installed CPU uint8 model, same uint8 front end: mean LSD 7.73 dB, STFT-magnitude SNR 8.6 dB (the CPU path's decoder is itself uint8-quantised). ASR round trip still to do.

## Device findings (Adreno 506, Mesa 26.2.6 from `/var/tmp/gpu-root`)

1. **GMEM (tiled) rendering faults with layered render targets.** With L >= 2 (several layers of one array texture attached as render targets) every draw fails: `gpu fault ring 0 ... status E40801C1` and `hangcheck recover`, output zero. With **`FD_MESA_DEBUG=sysmem`** (direct rendering to memory, no tiles) the same kernels run and verify. `sg_init` sets it (unless it is already set) before `eglInitialize`.
2. **Larger kernels write nothing (no fault, no hangcheck).** The conv kernel with its taps unrolled (`SG_UNROLL=1`), or with more than one output channel group per fragment (G = 2, 4: 8 or 16 output channels per fragment over L*G = 8 render targets), leaves the output exactly zero. Verified on a cleared output, with `FD_MESA_DEBUG=sysmem`, at 512, 8000 and 24000 time steps; the kernel log shows neither a gpu fault nor a hangcheck; the same GLSL is correct on the laptop (NVIDIA GLES 3.2). Hiding constant coordinate offsets from the compiler (`SG_NOFOLD=1`: every texelFetch coordinate XORed with a uniform zero) changes nothing. ir3 statistics (`IR3_SHADER_DEBUG=disasm`, `MESA_SHADER_CACHE_DISABLE=true`, `scripts/device-disasm.sh`; conv 128 -> 128 channels, kernel 11, dilation 1, fold 4):

   | Variant | Result | instr (nops) | dwords | half / full regs | max_waves | loops | cat3 / cat5 |
   | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
   | looped taps, L1 G1 (1 target) | correct | 483 (194) | 736 | 8 / 6 | 8 | 3 | 46 / 6 |
   | looped taps, L2 G1 (2 targets) | correct | 563 (209) | 864 | 10 / 6 | 8 | 3 | 68 / 7 |
   | looped taps, L4 G1, L8 G1 (4, 8 targets) | correct | not captured | | | | | |
   | **unrolled taps, L4 G1 (4 targets)** | **all zero** | 1418 (175) | 1920 | **48 / 48** | **2** | 2 | 748 / 59 |
   | looped taps, L4 G2, L2 G4 (8 targets) | all zero | not captured (the log was lost) | | | | | |

   So the failing shader is the one that uses the whole register file (48 full + 48 half, 2 waves, `double_threadsize` 0), against 6 full registers for the working ones; the G > 1 variants also hold 2-4x more accumulators and weight registers. A register-footprint limit for fragment shaders on a5xx (like the compute one gpu-compute found: work groups above about 16 full registers fault there), or an output-register/MRT issue at high register counts, is the likely cause. To reproduce: `sg-bench conv 128 128 8000 11 1 1` with `SG_CONFIGS="4,1,4" SG_UNROLL=1` (unrolled) or `SG_CONFIGS="4,2,4"` (G = 2); `SG_DIAG=1` prints the wrong fraction per channel group and phase (all wrong, output 0). The library's defaults avoid both (looped taps, G = 1).
3. **Throughput so far** (verified runs, no hangchecks, sysmem, looped taps, G = 1):

   | Kernel | L | GFLOP/s |
   | --- | ---: | ---: |
   | conv 128 -> 128 ch, k11, 24000 steps (stage 2's most common layer) | 1 | 4.93 |
   | same | 2 | 5.94 |
   | same | 4 | 6.77 |
   | same | 8 | 4.06 (fold 4), 4.23 (fold 16) |
   | GEMM 512 x 3584 x 4096 (1-tap conv) | 4, fold 16 | 12.50 |
   | same | 8, fold 16 | 5.91 |

   The ir3 statistics show about 40 % nops (texture latency) in the inner loop. gpu-compute's `f4h` GEMM reaches about 16 GFLOP/s on the same GEMM shape.

## If this is picked up again

- Find the limit behind finding 2 (patched Mesa, or kernels that stay under it: fewer live registers per fragment), then sweep L, G, fold and band size on the real layer shapes (`sg-bench kokoro 200`), and the ASR GEMM shapes (`sg-bench gemms`: M 40/80 x 1024x1024, 1024x3072, 3072x1024, FP16 and Q8 weights). The decoder needs about 45 GFLOP/s effective for real time with the CPU front end alongside.
- Then: device run of `kokoro-gpu-check`, the listener with `--tts-backend kokoro-gpu`, overlap of the next piece's front end with the current decoder, the ASR round trip, RTF, first audio, RSS and GPU memory, thermals, wake-detector timing, stop latency.
- Production would need Mesa installed on the root filesystem (root now has 3.7 GiB free) and in the image, and the front model (`scripts/kokoro-front-onnx.py`) and `.kdec` (`scripts/kokoro-ref.py export`) staged next to the Kokoro model.

## Left on the device

Nothing: the test binary (`/var/tmp/gpu-root/sg-bench`) and the shader cache (`/var/tmp/sg-cache`) were removed; the staged Mesa in `/var/tmp/gpu-root` belongs to gpu-compute. The listener runs its CPU configuration as before.

## Scripts

| Script | What |
| --- | --- |
| `scripts/kokoro-ref.py boundary\|torch\|weights\|export\|inputs` | ORT fp32 decoder inputs and waveform; PyTorch per-stage dumps; weights; the `.kdec` export; raw inputs |
| `scripts/kokoro-compare.py OUT TORCH.npz BOUNDARY.npz` | per-stage and waveform comparison |
| `scripts/kokoro-front-onnx.py IN OUT` | the uint8 model cut at the decoder |
| `scripts/kokoro-bench-lines.py` | `--g2p` output to `--tts-bench` lines |
| `scripts/wav-compare.py REF TEST` | WAV directories: SNR, STFT SNR, LSD |
| `scripts/device-bench.sh TAG ARGS` | `sg-bench` on the tablet under the lock (hangchecks and faults before/after) |
| `scripts/device-disasm.sh ARGS` | ir3 statistics of the kernels |
| `scripts/onnx-survey.py`, `scripts/onnx-msource.py` | graph inspection |

Results: `results/bench-*.log`.
