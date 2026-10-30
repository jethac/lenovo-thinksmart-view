# On-device speech recognition

Qwen3-ASR-0.6B on the ThinkSmart View, for short voice commands to a chatbot in English, Japanese and Mandarin. Recognition and synthesis run on the device; the chatbot's text inference runs on ai&'s servers (`GOAL.md`).

## Setup

- Runtime: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) at `5700f127e38dd53c4735ea23ef743b4b538eacd4`, statically cross-built for Cortex-A53 (`scripts/build-transcribe.sh`, `-mcpu=cortex-a53`, NEON, no dotprod), plus `patches/0001-qwen3_asr-quantized-conv-stem.patch`.
- Model: `handy-computer/Qwen3-ASR-0.6B-gguf` (`downloads/models/`, not in git). About 0.8B parameters: 18-layer bidirectional audio encoder (conv stem in 1 s chunks, attention in 8 s windows) feeding a 28-layer Qwen3 decoder.
- Test sets (`scripts/make-cmdset.py`): 15 short clips per language. English from LibriSpeech test-clean (2.0-2.8 s), Japanese and Mandarin from FLEURS test (6.4-7.5 s and 4.0-4.9 s). English is scored as WER with Whisper's English normaliser; Japanese and Mandarin as CER (`scripts/score.py`).
- Device runs: `scripts/device-bench-qwen.sh QUANT THREADS LANG` (model and clips in `/dev/shm`, under the device lock), `scripts/device-perf-qwen.sh` (transcribe.cpp's `TRANSCRIBE_PERF_DEBUG` breakdown). All numbers below are on the baseline kernel with the 75/85/100 °C thermal policy, CPUs at 1804.8 MHz, 8 threads, 2026-10-30.

## Results on the device

Time to text = mel + encode + decode, median over the 15 clips. RTF = time to text / audio length.

| Model | Language | Audio | Time to text | Encode | Decode | RTF | Accuracy | Peak RSS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Q4_K_M | en | 2.5 s | 5.64 s | 2.99 s | 2.65 s | 2.25 | WER 2.08 % | 917 MiB |
| Q4_K_M | zh | 4.7 s | 9.20 s | 5.02 s | 4.20 s | 2.03 | CER 2.61 % | 958 MiB |
| Q4_K_M | ja | 7.1 s | 13.98 s | 7.95 s | 6.01 s | 1.95 | CER 7.30 % | 1012 MiB |
| **Q4_K_M, conv stem Q8_0** | en | 2.5 s | **3.95 s** | 1.33 s | 2.63 s | **1.63** | WER 2.08 % | 944 MiB |
| **Q4_K_M, conv stem Q8_0** | zh | 4.7 s | **6.44 s** | 2.25 s | 4.22 s | **1.44** | CER 2.61 % | 1001 MiB |
| **Q4_K_M, conv stem Q8_0** | ja | 7.1 s | **9.49 s** | 3.55 s | 5.99 s | **1.34** | CER 6.46 % | 1087 MiB |

Other configurations, Mandarin set:

| Model, threads | Time to text | RTF | CER | Peak RSS |
| --- | --- | --- | --- | --- |
| Q4_K_M, 4 | 16.8 s | 3.65 | 2.61 % | 947 MiB |
| Q4_0, 4 | 16.9 s | 3.65 | 3.36 % | 825 MiB |
| Q4_0, 8 | 9.3 s | 2.01 | 3.36 % | 834 MiB |

- The quantisation format of the decoder makes no speed difference (Q4_0 = Q4_K_M), and Q4_K_M is more accurate.
- 8 threads (both clusters) is about 1.8x faster than 4.
- The conv-stem change gives identical transcripts on the laptop for all three languages; the Japanese CER difference on the device (6.46 % vs 7.30 % on 15 clips) is run-to-run noise.

Laptop reference (100 LibriSpeech clips, WER): Q8_0 1.75 %, Q5_K_M 1.81 %, Q4_K_M 1.96 %.

## Where the time goes

One 4.74 s Mandarin clip, 8 threads:

| Stage | Q4_K_M | conv stem Q8_0 | Bound by |
| --- | --- | --- | --- |
| Encoder | 4863 ms | 2213 ms | compute |
| Decoder prefill (80 tokens: 62 audio + prompt) | 2759 ms | 2767 ms | compute (~25 GFLOP/s, the CPU's Q8_0 ceiling) |
| Decoder steps | 1552 ms (15 x 103 ms) | 1535 ms (15 x 102 ms) | memory bandwidth |
| Mel, graph setup, readback | ~70 ms | ~75 ms | |

## The conv-stem change

The encoder's conv stem (`enc.conv.1/2.weight`, 3x3x480x480) is stored as F32 in the GGUF. `ggml_conv_2d` multiplies with the kernel as `src1` (which must be F32/F16) and builds its im2col in **F16**; this CPU has no FP16 arithmetic, so that multiply ran at about 4.4 GFLOP/s (measured in `../gpu-compute/`).

`patches/0001-qwen3_asr-quantized-conv-stem.patch`:
- the loader accepts `enc.conv.1/2.weight` either as the original 4D kernel or as a 2D `[3*3*IC, OC]` quantised matrix;
- for a 2D weight the encoder builds the im2col in F32 and multiplies with the weight as `src0` (the operand ggml can quantise), then restores `ggml_conv_2d`'s output layout. Unmodified GGUFs take the original path.

`scripts/requant-conv.py IN.gguf OUT.gguf` rewrites only those two tensors as 2D Q8_0 (max error 0.4 % of each tensor's range). Result: encoder 2.2x faster, end to end about 30 % faster, accuracy unchanged.

## The GPU

Not useful for this model: the Adreno 506 reaches about 14 GFLOP/s FP32 in OpenGL ES 3.1 compute shaders, half the CPU's Q8_0 rate, with slow readback and shared memory bandwidth (`../gpu-compute/NOTES.md`).

## Next

1. Run the conv stem while the user is still speaking (it works in independent 1 s chunks; the 8 s attention windows cannot start until speech ends).
2. Speculative decoding (`--spec-k-drafts`) for the decoder steps.
3. Shorter prompt: 18 of the 80 prefill tokens are prompt.
4. The output head is 122 MiB of Q6_K read on every decoder step; a lower-bit head would cut step time.
5. Choose and benchmark a speech synthesiser for English, Japanese and Mandarin; check recognition and synthesis fit in RAM together.
