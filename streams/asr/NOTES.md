# On-device speech recognition

Qwen3-ASR-0.6B on the ThinkSmart View, for short voice commands to a chatbot in English, Japanese and Mandarin. Recognition and synthesis run on the device; the chatbot's text inference runs on ai&'s servers (`GOAL.md`).

## Setup

- Runtime: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) at `5700f127e38dd53c4735ea23ef743b4b538eacd4`, statically cross-built for Cortex-A53 (`scripts/build-transcribe.sh`, `-mcpu=cortex-a53`, NEON, no dotprod), plus `patches/0001-qwen3_asr-quantized-conv-stem.patch` and `patches/0002-qwen3_asr-incremental-conv-stem.patch` (apply in order with `git apply`).
- Model: `handy-computer/Qwen3-ASR-0.6B-gguf` (`downloads/models/`, not in git). About 0.8B parameters: 18-layer bidirectional audio encoder (conv stem in 1 s chunks, attention in 8 s windows) feeding a 28-layer Qwen3 decoder.
- Test sets (`scripts/make-cmdset.py`): 15 short clips per language. English from LibriSpeech test-clean (2.0-2.8 s), Japanese and Mandarin from FLEURS test (6.4-7.5 s and 4.0-4.9 s). English is scored as WER with Whisper's English normaliser; Japanese and Mandarin as CER (`scripts/score.py`).
- Device runs: `scripts/device-bench-qwen.sh QUANT THREADS LANG` (model and clips in `/dev/shm`, under the device lock), `scripts/device-perf-qwen.sh` (transcribe.cpp's `TRANSCRIBE_PERF_DEBUG` breakdown, one clip) and `scripts/device-perf-set-qwen.sh` (the same over whole sets), `scripts/device-stream-qwen.sh` (latency after the end of speech, offline vs streaming). All numbers below are on the baseline kernel with the 75/85/100 °C thermal policy, CPUs at 1804.8 MHz, 8 threads, 2026-10-30.

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

## Conv stem while the user is speaking

`patches/0002-qwen3_asr-incremental-conv-stem.patch` (on top of 0001) runs the encoder's conv stem on each 1 s chunk as soon as its audio has arrived, so that after the end of speech only the last chunk's conv stem, the encoder transformer and the decoder remain.

Share of the encoder that can move (device, Q4_K_M + Q8_0 conv stem, 8 threads, median over each set, `scripts/device-perf-set-qwen.sh`; the perf breakdown now has a `conv_stem` line):

| Set | Audio | Chunks | Encoder | Conv stem | Share |
| --- | --- | --- | --- | --- | --- |
| en | 2.5 s | 3 | 1229 ms | 781 ms | 63 % |
| zh | 4.7 s | 5 | 2161 ms | 1304 ms | 60 % |
| ja | 7.1 s | 7-8 | 3406 ms | 2065 ms | 60 % |

About 260 ms per chunk. The conv stem includes `conv_out` (the linear projection is per time step, so per chunk); the positional embedding is added in the encoder graph and is the same for every chunk.

### Method

- API: the existing `transcribe_stream_begin` / `transcribe_stream_feed` / `transcribe_stream_finalize` (`include/transcribe.h`). qwen3_asr now implements the hooks and sets `supports_streaming`. Feed takes PCM in any slice size; text appears only at finalize. Utterances shorter than one chunk fall back to the offline path. The offline path (`transcribe_run`) is unchanged: transcripts and all 13 dumped tensors (`TRANSCRIBE_DUMP_DIR`) are byte-identical to a base + 0001 build.
- Mel frames. Frame t is the STFT of samples [160t - 200, 160t + 200) of the reflect-padded input, so it is final once sample 160t + 200 has arrived. Each feed computes the newly final frames with a second frontend in a new `log10` mode (the Whisper log-mel before normalisation) over a slice of the received audio that starts two frames early, so the slice's own start padding never reaches a wanted frame; the frames are computed from the same samples by the same code as offline. The last frames (where the end-of-input reflection reaches) are computed at finalize.
- Normalisation. The frontend clamps every value to (utterance max - 8) before scaling, so a chunk normalised with the running max differs from offline once a louder frame arrives. Each time a chunk completes, every earlier chunk is renormalised with the current max and re-run if its normalised mel changed (bitwise compare); finalize does the same with the final max. Band-limited clips (with mel bins that are always clamped) need a re-run of every earlier chunk whenever the max rises. Re-running at chunk completion rather than at finalize moves that work into the speech: 40 of the 189 chunks run during feed were re-run, all of them during feed, none at finalize, on the 45 clips.
- Each chunk's conv output depends only on its own mel (offline already runs chunks as an independent batch), so the result does not depend on when or with which other chunks it ran.
- `transcribe-cli --stream-chunk-ms N --stream-realtime` (batch JSONL) feeds N ms slices when they would have finished arriving from a microphone (sleeping in between) and reports `latency_ms` from the end of the audio to the final text, plus process CPU time during and after the audio. Without `--stream-chunk-ms` it times the offline run on the same timeline (wait for the whole clip, then transcribe).

### Verification (laptop)

`scripts/laptop-stream-check.py --chunk-ms N` runs every clip of the three sets offline and streaming, each with its own dump directory: for 37, 100, 160 and 200 ms slices, all 45 transcripts are identical and the mel, conv-stem output and encoder output are bit-identical (max abs difference 0).

### Results on the device

`scripts/device-stream-qwen.sh Q4_K_M-convq8 8 "en ja zh" 160`, summarised by `scripts/summarise-stream.py`. Each clip is spoken in real time (160 ms slices); latency = end of the audio to the final text, median over the 15 clips.

| Set | Audio | Offline latency | Streaming latency | Saved | Encode after speech | Accuracy (both) |
| --- | --- | --- | --- | --- | --- | --- |
| en | 2.5 s | 3.77 s | **3.34 s** | 0.43 s (11 %) | 1273 -> 710 ms | WER 2.08 % |
| zh | 4.7 s | 6.21 s | **5.06 s** | 1.15 s (19 %) | 2232 -> 1111 ms | CER 2.61 % |
| ja | 7.1 s | 9.23 s | **7.42 s** | 1.81 s (20 %) | 3519 -> 1575 ms | CER 6.46 % |

Transcripts identical between the two modes on all 45 clips. The decoder (2.5-5.7 s) is now most of what remains.

Load while the user speaks (streaming mode; offline does nothing during the audio):

| Set | CPU during audio | Average cores | Longest feed call | CPU per clip, offline / streaming | Re-runs during audio |
| --- | --- | --- | --- | --- | --- |
| en | 3.9 s | 1.5 | 551 ms | 29.1 / 29.1 s | 4 |
| zh | 8.0 s | 1.8 | 832 ms | 48.2 / 48.1 s | 6 |
| ja | 15.9 s | 2.4 | 1110 ms | 71.9 / 74.4 s | 30 |

Each chunk is a burst on all 8 threads (about 260 ms, longer when earlier chunks are re-run with it); total CPU is unchanged except for the re-runs (ja +3 %). The CPU totals are about 8 x the compute wall time because ggml's worker threads busy-wait between operations. A wake-up probe (`scripts/wakeprobe/`, a normal-priority thread sleeping 10 ms in a loop) shows other threads stay responsive: idle p99 0.3 ms; while the audio arrives (streaming) p99 1.0-1.2 ms, max 6 ms; after the audio (both modes, all 8 cores busy) p99 about 2 ms, max 8 ms; no wake-up late by more than 16 ms in any phase. CPU-heavy work running at the same time (synthesis) would share the cores.

Left open:
- A live caller should feed from a thread that does not also capture audio: a feed call that completes a chunk blocks for 260 ms to 1.1 s (several re-runs at once).
- The last, partial chunk still runs a full 100-frame conv stem at finalize (about 260 ms). A narrower graph for it would need care to stay bit-exact at its padded edge (padding positions carry GELU(bias), not zero, after the first conv).
- The transformer attends over the whole utterance (as the reference's eager path, not `n_window_infer` windows), so it cannot start before the end of speech.

## The GPU

Not useful for this model: the Adreno 506 reaches about 14 GFLOP/s FP32 in OpenGL ES 3.1 compute shaders, half the CPU's Q8_0 rate, with slow readback and shared memory bandwidth (`../gpu-compute/NOTES.md`).

## Next

1. Speculative decoding (`--spec-k-drafts`) for the decoder steps.
2. Shorter prompt: 18 of the 80 prefill tokens are prompt.
3. The output head is 122 MiB of Q6_K read on every decoder step; a lower-bit head would cut step time.
4. Choose and benchmark a speech synthesiser for English, Japanese and Mandarin; check recognition and synthesis fit in RAM together.
