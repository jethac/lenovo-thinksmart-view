# On-device speech synthesis: MagpieTTS Multilingual 357M

NVIDIA's MagpieTTS Multilingual 357M (v2607) with the NeMo NanoCodec decoder, for the assistant's spoken replies in English, Japanese and Mandarin on the ThinkSmart View.

**Result: it runs on the device, in all three languages, without Python, but about 8.5x slower than real time on all 8 cores (16x on 4).** The first audio comes after 8-10 s, and a sentence-by-sentence stream cannot stay continuous. The codec decoder alone needs about 54 GFLOP per second of audio. The CPU's best ggml rate is 25-28 GFLOP/s, so even a perfectly efficient codec would be 2x slower than real time before the token generator runs. No tuning of this model closes that gap on this SoC. See [Can it be real time?](#can-it-be-real-time).

Measured 2026-10-31 on the baseline kernel (after stage B), CPUs at 1.4-1.6 GHz at the start of each run (schedutil), CPU zones under 49 °C throughout.

## Model, licence, provenance

- Model: [`nvidia/magpie_tts_multilingual_357m`](https://huggingface.co/nvidia/magpie_tts_multilingual_357m) at revision `446bff55e1fe3d3aa29c771574e7d2b0fa322990` (v2607). Encoder-decoder transformer, 364M parameters: 6-layer text encoder, 12-layer decoder, 2-layer local transformer that predicts 8 codebooks for 2 stacked frames per decoder step, classifier-free guidance (CFG) on by default. Output: NanoCodec tokens at 21.5 frames/s, decoded to 22.05 kHz mono. 12 languages (ar, de, en, es, fr, hi, it, ja, ko, pt, vi, zh); up to about 20 s per request in standard mode.
- Speakers (v2607 `speakers.json`): 0 Aria, 1 Jason, 2 John (Van Stan, a LibriVox reader), 3 Leo, 4 Sofia. Aria and Sofia are female, the others male. NVIDIA labels them all US English (`Magpie-Multilingual.EN-US.<name>`), and every speaker speaks every language. Zero-shot voice cloning was removed in this release.
- Codec: [`nvidia/nemo-nano-codec-22khz-1.89kbps-21.5fps`](https://huggingface.co/nvidia/nemo-nano-codec-22khz-1.89kbps-21.5fps) at `fc00890b604aa2de298d2641ffc6c5f6caf8c4d7`.
- Files used (`downloads/models/`, SHA-256 checked against the Hugging Face LFS pointers): `magpie_tts_multilingual_357m.nemo` (`ec675fa8…8953`), `magpie_tts_multilingual_357m.v2607.q8_0.gguf` (`318c8f83…50cf9`, NVIDIA's own conversion; its `magpietts.speaker_names` metadata is in the v2607 order above), `nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf` (`cc86d36d…ef2d`). The tokenizer assets (`model_config.yaml`, G2P dictionaries, `speakers.json`) are extracted from the `.nemo`, 20 MB.
- **Licence: NVIDIA Open Model License** (both model and codec; text as of its 24 Oct 2025 revision):
  - commercial use is allowed; NVIDIA claims no rights in generated audio;
  - redistribution (for example the weights inside the device image) is allowed if recipients get a copy of the agreement and a "Notice" text file saying "Licensed by NVIDIA Corporation under the NVIDIA Open Model License";
  - the rights end if you sue claiming the model infringes, or if you bypass the model's guardrails without an equivalent replacement; use must follow NVIDIA's Trustworthy AI terms; NVIDIA may update the licence;
  - no trademark rights beyond naming the model's origin.

  So the image may ship the GGUFs as long as it carries the licence text and that Notice file. The runtime and front end are separate licences: NeMo-Speech.cpp Apache-2.0; Open JTalk (modified BSD), MeCab (BSD/LGPL/GPL, choose BSD), NAIST Japanese dictionary (BSD); cppjieba and limonp (MIT); the bundled pinyin tables (from pypinyin, MIT).

## Runtime

- [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp) at `20999cc921d2b14aa58708f61756a8b2e787ba20`: NVIDIA's own C++ runtime for Magpie on ggml, the same approach as transcribe.cpp for the ASR. It replaces the ONNX plan: NVIDIA maintains it, it reads NVIDIA's own GGUF, and it has native Japanese and Mandarin front ends.
- `scripts/build-nemo-speech.sh native|a53`: TTS only, with `NEMO_SPEECH_TTS_WITH_JA` (Open JTalk + MeCab + NAIST dictionary, built in-tree) and `NEMO_SPEECH_TTS_WITH_ZH` (cppjieba + bundled pinyin tables, Git LFS). The a53 build is cross-compiled with the asr stream's toolchain and sysroot (Cortex-A53, NEON, no dotprod, fully static) and runs the aarch64 `mecab-dict-index` under `qemu-aarch64` to compile the dictionary. That dictionary is byte-identical to the laptop's.
- Local patches (`patches/`, applied by the build script):
  - `0001` makes the `nemo_speech_tts` library type a cache option, so the device binary can be fully static;
  - `0002` adds a Q8_0 path for the codec's CPU convolutions (`NANOCODEC_CPU_Q8=1`, off by default), described below.
- On the device: `nemo-speech` (8.3 MB static), the Magpie Q8_0 GGUF (317 MiB), codec F16 GGUF (75 MiB), tokenizer assets (20 MB), Open JTalk dictionary (65 MB), Mandarin tables (7 MB).
- Not used: the ONNX export [`OpenVoiceOS/phoonnx-magpie-tts`](https://huggingface.co/OpenVoiceOS/phoonnx-magpie-tts). It is a third-party format conversion of the same v2607 weights (same NVIDIA licence, F32 graphs), and it needs phoonnx's Python front end. It runs the same codec, whose FLOP count is what makes this model too slow (below), so ONNX Runtime cannot change the conclusion. Not measured.

## Text front end (no Python)

- English: IPA from CMUdict (`ipa_cmudict-0.7b_nv23.01`) with heteronyms. Japanese: Open JTalk/MeCab to katakana with accent marks (NeMo's `JapaneseKatakanaAccentG2p`, which uses pyopenjtalk). Mandarin: jieba segmentation, pypinyin-compatible tables, the model's pinyin-to-IPA dictionary. All of it is native C++.
- **Parity with NeMo** (`src/magpie-tokens.cpp` vs `scripts/nemo-tokens.py`, NeMo `a837f4e5`, the nine lines in `cases/lines.tsv`):
  - Mandarin: token IDs identical.
  - English: identical whenever NeMo phonemises a word. NeMo's `do_tts()` builds its tokenizer in training mode, and in this NeMo version `set_phone_prob(1.0)` does not take effect either, so NeMo spells about 20 % of English words as letters at random (`phoneme_probability: 0.8`). The C++ front end always uses phonemes, which is what inference should do.
  - Japanese: identical for plain Japanese. Latin letters differ: NeMo passes them through as letters; the C++ front end turns them into katakana letter names. Either way the model spells English words out (ASR hears "Z O O M" for "Zoom"). **Japanese replies should write English names in katakana** (ズーム, スラック, マーケティング were read correctly).
  - The device produces the same tokens as the laptop for all nine lines.
- Speed on the device (`scripts/device-frontend.sh`): 0.1-1.1 ms per sentence once loaded. The first call per language loads its dictionaries: English 2.2 s (CMUdict), Mandarin 2.0 s (jieba), Japanese 3 ms (memory-mapped MeCab dictionary). The runtime warms up at start-up, so requests do not pay that cost.
- Text normalisation (numbers, dates) is not built (`NEMO_SPEECH_WITH_NORM` needs OpenFST/Sparrowhawk). The lines here are written in spoken form. The chatbot should send spoken-form text, or normalisation needs adding later.

## Samples (laptop)

`work/samples/<speaker>-<line>.wav` (git-ignored) has all 5 speakers x 9 lines (3 per language; `ja-3` mixes English into Japanese), made with the laptop build and the same Q8_0 GGUF as the device, seed 1. `work/samples/INDEX.md` lists speaker, gender, language, the exact text, and notes per female speaker. `work/samples-nemo/` (Sofia) and `work/samples-nemo-b/` (the other four) hold the same lines from NeMo itself (`scripts/nemo-reference.py`, CUDA on the laptop's 4 GB GTX 1650 Ti). That run uses the decoder KV cache, as the C++ runtime does, and drops the codec's unused encoder so it fits in 4 GB.

ASR round trip (Qwen3-ASR Q8_0 on the laptop, `scripts/analyse-samples.py`), mean CER per language, all speakers:

| | English | Japanese | Mandarin |
| --- | --- | --- | --- |
| NeMo-Speech.cpp, Q8_0 (what the device runs) | 7.5 % | 9.4 % | 0.9 % |
| NeMo reference (PyTorch, F32) | 8.5 % | 11.4 % | 1.0 % |

English CER is mostly digits ("2:30" for "two thirty"); Japanese errors are the spelled-out English words, the dropped "B" in 会議室B, and 四半期 heard as 市販機. The C++ port is at least as intelligible as NeMo itself.

Fit to the brief (user's choice of accent: General American): **Sofia** is the first to audition (NVIDIA's recommended US female voice; median pitch about 195 Hz), **Aria** the second (slightly lower, steadier, faster). Details in `work/samples/INDEX.md`. These notes come from measurements, not listening.

## Device results

`scripts/device-tts.sh cases/bench.txt` (Sofia, seed 1, models in `/dev/shm`, each run in a systemd scope capped at 1300 MiB). "8 threads" = Magpie 3 + codec 5, "4 threads" = 2 + 2, Q8_0 codec path on. Lines `*-2` are one sentence, `*-3` are the 3-sentence replies (`ja-3` is two sentences with English words). First audio = request start to the first decoded audio chunk. Stall = silence a listener would hear if playback started at the first audio. Decoder step = one autoregressive step = 2 codec frames = 93 ms of audio; avg is while the codec runs alongside it, min is the uncontended step. Codec chunk = 4 frames = 186 ms of audio.

| Run | Audio | First audio | Total | RTF | Stall | Text encoder | Decoder step (avg / min) | Codec chunk 186 ms (avg) | Peak RSS |
|---|---|---|---|---|---|---|---|---|---|
| en-2-t8 | 5.8 s | 8.6 s | 51.7 s | 9.0 | 37.4 s | 2.3 s | 630 / 248 ms | 1438 ms | 767 MiB |
| en-2-t4 | 5.8 s | 13.1 s | 95.7 s | 16.6 | 76.9 s | 3.4 s | 1175 / 334 ms | 2755 ms | 860 MiB |
| en-3-t8 | 9.4 s | 9.7 s | 79.9 s | 8.5 | 60.8 s | 3.5 s | 656 / 248 ms | 1404 ms | 892 MiB |
| en-3-t4 | 9.4 s | 14.9 s | 150.9 s | 16.1 | 126.6 s | 5.1 s | 1260 / 334 ms | 2720 ms | 802 MiB |
| ja-2-t8 | 5.3 s | 7.7 s | 46.4 s | 8.8 | 33.4 s | 1.6 s | 609 / 248 ms | 1382 ms | 797 MiB |
| ja-2-t4 | 5.3 s | 12.0 s | 87.5 s | 16.5 | 70.2 s | 2.4 s | 1171 / 330 ms | 2696 ms | 795 MiB |
| ja-3-t8 | 11.3 s | 7.9 s | 98.1 s | 8.7 | 78.9 s | 3.8 s | 627 / 248 ms | 1503 ms | 873 MiB |
| ja-3-t4 | 11.3 s | 12.3 s | 177.6 s | 15.7 | 153.9 s | 5.3 s | 1135 / 332 ms | 2755 ms | 870 MiB |
| zh-2-t8 | 6.8 s | 8.2 s | 58.8 s | 8.7 | 43.8 s | 2.1 s | 636 / 247 ms | 1405 ms | 992 MiB |
| zh-2-t4 | 6.8 s | 12.7 s | 110.6 s | 16.3 | 91.1 s | 3.1 s | 1220 / 333 ms | 2718 ms | 915 MiB |
| zh-3-t8 | 11.2 s | 9.7 s | 95.1 s | 8.5 | 74.2 s | 3.5 s | 672 / 250 ms | 1423 ms | 917 MiB |
| zh-3-t4 | 11.2 s | 14.8 s | 178.1 s | 15.9 | 152.1 s | 5.1 s | 1277 / 334 ms | 2722 ms | 999 MiB |

- Speed is the same in all three languages (RTF 8.5-9.0 on 8 threads, 15.7-16.6 on 4). Speed depends on audio length, not language.
- **Where the time goes** (8 threads, en-2):
  - text front end: under 1 ms;
  - text encoder: 1.6-3.8 s, proportional to text length (6 layers with convolutional FFNs, about 23 GFLOP for 115 tokens, on 3 threads);
  - decoder prefill over the speaker's 217-frame baked context and the first steps: about 4.4 s;
  - first codec chunk: 1.6 s.

  That adds up to 8.6 s to first audio. After that:
  - token generation runs at 248 ms per step alone and 630 ms per step next to the codec (2.7x and 6.8x slower than real time);
  - the codec takes 1.4 s per 186 ms chunk (7.6x).
- **Streaming sentence by sentence does not keep speech continuous**: each sentence takes about 8.5x its own length, so playback would stall for most of the reply (the Stall column). Continuous playback needs nearly the whole reply buffered first.
- Peak RSS 770-1000 MiB: about 400 MiB of weights, the codec's repacked weights, compute buffers, and in Mandarin about 120 MiB of jieba and pinyin tables.

### What was tried (en-2, Sofia, 8 cores)

| Configuration | RTF | First audio | Peak RSS |
| --- | --- | --- | --- |
| Runtime defaults: 8 Magpie threads + 8 codec threads | **49.0** | 11.6 s | 723 MiB |
| 4 + 4 | 11.3 | 7.3 s | 725 MiB |
| 3 + 5 | 9.7 | 8.5 s | 725 MiB |
| 2 + 6 | 9.1 | 11.7 s | 821 MiB |
| 3 + 5, Q8_0 codec (`NANOCODEC_CPU_Q8=1`) | **8.9** | 8.4 s | 865 MiB |
| 3 + 5, no CFG | 9.5 | 8.4 s | 657 MiB |

- **Thread oversubscription was the first problem.** The runtime gives the token generator and the codec worker the same thread count, and they run in parallel. Two spinning 8-thread ggml pools on 8 cores ran 5x slower than splitting the cores (RTF 49 vs 9-10). Splitting them 3 + 5 is the fix.
- **Codec weights, the Qwen3-ASR lesson** (`scripts/device-codec.sh`, codec alone, 64 frames, 4-frame streaming chunks):

  | Codec weights | 8 threads | 4 threads |
  | --- | --- | --- |
  | F16 (as published) | RTF 5.56 | 10.15 |
  | F16, convolutions as Q8_0 (patch 0002) | 5.54 | 8.10 |
  | F32 (converted locally from the `.nemo`) | 8.43 | 13.51 |

  Patch 0002 quantises the codec's stride-1 convolutions (input channels zero-padded to 32) and the transposed convolutions' GEMM weights to Q8_0 at load. It runs them as an F32 im2col plus a matmul with the Q8_0 weight as `src0`, like the ASR conv-stem change. It helps on 4 threads (20 %) but not on 8: the codec is limited by memory traffic, not by the F16 arithmetic. Its im2col expands each activation by the kernel size (3, 7 or 11), about 3 GB/s of traffic per second of audio, and the channel counts (27·2^n) are awkward for tiling. It costs 140 MiB more RSS for 3-8 % end to end, so leave it off. Quality: 24-28 dB SNR against the F16 path on the same tokens. F32 is slower than F16 here, because it doubles that traffic.
- The Magpie GGUF already has every linear layer in Q8_0 (F16 only for embedding tables, which are lookups), so there was nothing left to quantise there.
- No CFG nearly halves the uncontended decoder step (137 vs 248 ms) but does not change end-to-end speed, which the codec sets.
- **Offline (non-streaming) codec decoding ran the tablet out of memory.** `--tts.chunk-frames 1000`, which decodes all frames at once, needs memory proportional to utterance length. With Magpie loaded it exhausted the 1.9 GiB, and the kernel OOM killer took adbd, NetworkManager, wpa_supplicant and the idle screen (they restarted, and I restarted `tsv-idle-screen`). Every device run since then is in a memory-capped systemd scope. Keep the codec streaming (the default 4-frame chunks).

## Can it be real time?

No, not on this CPU with this model:

- The NanoCodec decoder has 97 convolutions and does **54.3 GFLOP per second of audio** (`scripts/codec-flops.py`; most of it in the residual stacks at 108-216 channels and 1.4-5.5 kHz). The A53 cluster's best ggml rate is 25-28 GFLOP/s (Q8_0 GEMM, `../gpu-compute/`). So the codec alone, at 100 % efficiency on all 8 cores, would be 2x slower than real time. Measured, it is 5.5x.
- The token generator adds about 1.4 GFLOP per 93 ms step (12-layer decoder and 16 sequential local-transformer steps, each as a CFG pair). Mostly that is about 340 MB of weight reads per step, so it needs 110 ms or more per 93 ms step on its own memory bandwidth. Measured: 248 ms alone.
- The GPU does not help (14 GFLOP/s, `../gpu-compute/NOTES.md`).

The full pipeline is 8.5x slower than real time; no rewrite of this model gets it under about 3x. What would close the gap:

1. **Synthesise on ai&'s servers and stream the audio** (the chatbot reply is generated there anyway). NVIDIA reports 60x real time for the same model on an RTX 4090; the device then only plays a 22 kHz stream, and the voice stays the same.
2. Or a much lighter on-device model: a VITS/Piper-class model needs roughly an order of magnitude less compute per second of audio than this codec alone. Such a model would need its own Japanese and Mandarin check.
3. Inside Magpie, only partial gains are left, none enough: a fused direct-convolution NEON kernel for the codec (removes the im2col traffic; best case about 2x on the codec); a cheaper vocoder trained for Magpie's tokens; shorter first audio by encoding and generating sentence by sentence (the text encoder is 1.6-3.8 s of the first-audio time).

## Speaker output path

`scripts/device-play.sh work/samples/sofia-en-1.wav` played the 2.7 s greeting through PipeWire's "Built-in Audio Speaker". Sink volume was 0.30 (amp control `Speaker Amp Digital` 145 = -31.0 dB); `pw-play` returned 0 in 3.0 s, and the volume was restored to 0.30. There is no login session over adb, so the script starts jethac's user manager and PipeWire for the test and stops them afterwards. An assistant service will need its own PipeWire session (lingering user or a system service).

## Memory: Magpie and Qwen3-ASR together

`scripts/device-memory.sh` (models on the root filesystem, the realistic deployment; page cache dropped before each run; everything in one systemd scope capped at 1550 MiB so the system services keep their share). ASR = Qwen3-ASR Q4_K_M with the Q8_0 conv stem, 15 Japanese clips in one batch, 8 threads. TTS = the 3-sentence Japanese reply, 3 + 5 threads, F16 codec. "both" starts them together.

| Run | ASR time | TTS time | ASR peak RSS (anon + file) | TTS peak RSS (anon + file) | Lowest MemAvailable | Major faults ASR / TTS |
|---|---|---|---|---|---|---|
| ASR alone | 158 s | - | 1087 MiB (536 + 551) | - | 1119 MiB | 1024 / - |
| TTS alone | - | 125 s | - | 824 MiB (812 + 12) | 843 MiB | - / 149 |
| both | 303 s | 168 s | 1085 MiB (537 + 549) | 757 MiB (746 + 11) | 387 MiB | 49093 / 173 |

- **They fit together** (MemTotal 1941 MiB, about 270 MiB used by the system at idle): no OOM, lowest MemAvailable 387 MiB, and the ASR transcripts were identical to the solo run.
- Most of the memory cannot be reclaimed. Magpie copies its weights into anonymous memory (about 750-810 MiB, nothing file-backed to evict), and the ASR has about 540 MiB anonymous. Only the ASR's 550 MiB memory-mapped GGUF is evictable, and under pressure the kernel drops and re-reads it: 49,000 major faults instead of 1,000, i.e. weights re-read from eMMC. The ASR's doubled time in "both" is mostly the two sharing 8 cores, but in normal use (listen, then speak) the ASR would pay that re-read whenever the TTS has pushed its pages out.
- Mandarin TTS needs about 120 MiB more than Japanese (jieba and pinyin tables; peak RSS up to 1000 MiB), which leaves about 250 MiB at the worst moment.
- So they can stay loaded together, with no headroom for anything else. Keep the codec streaming (offline decoding ran the device out of memory, see above), and leave the Q8_0 codec patch off (+140 MiB). If memory gets tight, alternate (unload the TTS after speaking) or run the TTS on the server, which also solves the speed problem.

## Scripts

| Script | What |
| --- | --- |
| `scripts/build-nemo-speech.sh native\|a53` | build NeMo-Speech.cpp (TTS, ja + zh front ends), laptop or device |
| `patches/0001-*.patch`, `0002-*.patch` | static TTS library option; Q8_0 codec convolutions on the CPU |
| `src/magpie-tokens.cpp`, `scripts/build-magpie-tokens.sh` | front-end tokens and timing |
| `scripts/nemo-tokens.py`, `scripts/nemo-reference.py` | NeMo's tokens and NeMo reference audio (`downloads/nemo-venv`, NeMo `a837f4e5`, torch 2.8 cu126) |
| `scripts/laptop-samples.sh` | the listening samples, all speakers |
| `scripts/analyse-samples.py`, `scripts/wavdiff.py`, `scripts/codec-flops.py` | pitch/rate/ASR round trip; SNR between two WAVs; codec FLOPs |
| `scripts/device-tts.sh CASES OUT`, `scripts/summarise-device.py` | device synthesis runs (locked, memory-capped, detached so an adbd restart does not lose them) and their table |
| `scripts/device-codec.sh`, `scripts/device-frontend.sh` | codec alone; front end alone |
| `scripts/device-memory.sh` | ASR and TTS together, models on root |
| `scripts/device-play.sh` | one short sample through the speaker at volume 0.3 |
| `cases/lines.tsv`, `cases/bench.txt`, `cases/exp1.txt` | texts and device case lists |

## Left on the device

Nothing: `/dev/shm/tts*` and `/var/tmp/ttsmem` were removed, the user manager started for playback was stopped, and the sink volume is back at 0.30. The OOM described above restarted several system services; all are active again (`tsv-idle-screen` restarted by hand).

# Kokoro-82M (hexgrad, v1.0)

Kokoro-82M v1.0 replaces Magpie as the on-device voice: it is the reply voice of `straylight-listen` (straylight-voice `listen/src/tts/`), installed and running on the tablet. Kokoro is much smaller than Magpie, but **it is still about 3x slower than real time on this CPU** (RTF 2.9-3.0 on 6 threads, in all three languages). The reason is again the vocoder: Kokoro's iSTFTNet generator needs about 48 GFLOP per second of audio, and the A53 cluster's best rate is about 25 GFLOP/s. So replies are spoken piece by piece (clauses and sentences) with pauses between pieces, not as continuous speech. See [Can Kokoro keep up?](#can-kokoro-keep-up).

Measured 2026-10-31 on the baseline kernel, schedutil up to 1.8 GHz.

## Runtime: ONNX Runtime, from Rust, in the listener's process

- **Model**: onnx-community's export of v1.0 (`onnx-community/Kokoro-82M-v1.0-ONNX` at `1939ad2a`), the `model_uint8.onnx` variant (QLinearConv/QLinearMatMul, 177 MB). `scripts/kokoro-onnx-durations.py` adds the duration predictor's rounded per-token durations (the tensor feeding the alignment's CumSum) as a second output, so the player can map playback time to text. Nothing else changes.
- **Runtime**: ONNX Runtime 1.28.2 (`libonnxruntime.so` from sherpa-onnx v2.0.1's linux-aarch64 build, MIT), opened at run time by the `ort` crate (2.0.0-rc.15, load-dynamic, API 24), so the binary has no link-time dependency on it. Intra-op threads 6, spinning off (the pool sleeps between runs and leaves the cores to capture), nice 5 like the recogniser (ORT's threads are made by the synthesis thread and inherit it), graph optimisation level 3.
- **Why not sherpa-onnx's Kokoro support**: its English front end is espeak-ng, linked into the library (GPL-3.0, in-process), and it has no Japanese front end for Kokoro. **Why not a ggml port**: none was mature enough for all three languages; the cost is the vocoder's arithmetic either way (below), so a different runtime would not change the conclusion.

### Variants (device, `straylight-listen --tts-bench`, en-cal: 105 tokens, 6.55 s of audio)

| Model | Threads | RTF | Peak RSS | CPU s |
| --- | --- | --- | --- | --- |
| fp32 (`model.onnx`, 326 MB) | 4 | 4.43 | 521 MiB | 102 |
| fp32 | 6 | 3.30 | 539 MiB | 107 |
| fp32, spinning on | 6 | 3.18 | 526 MiB | 120 |
| int8 dynamic (`model_quantized.onnx`, ConvInteger/MatMulInteger) | 4 | 6.27 | 304 MiB | 87 |
| **uint8 static (`model_uint8.onnx`)** | 4 | 3.78 | 404 MiB | 87 |
| **uint8 static** | **6** | **2.94** | **407 MiB** | 93 |

- Dynamic int8 is the slowest: without dotprod, ORT's ConvInteger on ARMv8.0 is worse than its fp32 im2col+SGEMM. The static uint8 model is 12 % faster than fp32 and 130 MiB smaller. Quality: an ASR round trip (Qwen3-ASR Q8_0, `scripts/kokoro-asr-check.py`, 65 lines: 25 en, 20 ja, 20 zh, af_heart / jf_alpha / zf_xiaoni) gives CER 6.65 / 7.12 / 7.83 % for fp32 and 7.42 / 8.44 / 7.85 % for uint8: within the noise of 20-25 lines (most English errors are digits written for spoken numbers). uint8 is installed.
- Spinning buys 4 % at the cost of 13 % more CPU; left off.
- 6 threads is the budget while speaking (the recogniser is idle). 4 threads is 28 % slower.
- The thread-split lesson from Magpie does not arise: Kokoro is one graph in one session, one pool.

## Can Kokoro keep up?

`scripts/kokoro-profile.py` (ORT profile, laptop, 1 thread, en-cal): 85 % of the time is the decoder's generator (its residual blocks and the two noise residual blocks), 72 % of it in Conv. Its stages run 256 channels at 800 Hz and 128 channels at 4800 Hz (to the 5-sample-hop iSTFT at 24 kHz), with kernels 3/7/11 and three dilations, two convolutions each: about 24 GMAC (48 GFLOP) per second of audio. At 6 threads the device achieves about 14.5 GFLOP/s (RTF 3.3 fp32), which is three quarters of what 6 of the 8 cores can do. Even all 8 cores at peak would leave it about 2x slower than real time. Nothing short of a cheaper vocoder (or synthesis off the device) makes the stream continuous.

## Text front end (Rust, no Python, no GPL)

All in straylight-voice `listen/src/tts/g2p/`; data made by `scripts/kokoro-frontend-data.py` (and copied there as `listen/scripts/`).

- **English** (`en.rs`): a port of misaki's `en.G2P` with its gold and silver US lexicons (365k entries). The special cases, stress rules, -s/-ed/-ing stems, numbers (num2words in `num_en.rs`) and the "the/to" vowel context are ported line by line. Differences:
  - no spaCy: a small tokenizer, and a rule tagger for what the lexicon needs (determiners, prepositions, PRP "I", NNP for all-capitals and mid-sentence capitals, and noun/verb/participle from the word before);
  - unknown words go to **g2p_en's GRU network** (Apache-2.0, trained on CMUdict; 3.3 MB) mapped from ARPAbet to misaki's phonemes, instead of espeak-ng;
  - clock times are read as spoken ("9:30" nine thirty, "10:05" ten oh five);
  - `en-extra.lex` adds "Straylight".
- **Japanese** (`ja.rs`): misaki's `JAG2P` as Kokoro v1.0 uses it (the cutlet path), with **MeCab and the NAIST Japanese Dictionary from Open JTalk 1.11** (BSD; r9y9/open_jtalk `1e52154e`, the same dictionary bytes as the Magpie build, 65 MB, memory-mapped) instead of fugashi + UniDic 3.1 (770 MB). Differences:
  - punctuation kept: with UniDic, misaki's cutlet drops every 、 and 。 (their pronunciation field is `*`, read as a kana it does not know);
  - numbers with common counters read properly (3日 みっか, 4時 よじ, 15分 じゅうごふん, 2時間, 4人, 1回); misaki reads the number and leaves the counter to the dictionary (3日 as さんび);
  - the volitional う after an o-row syllable as a long vowel (ましょう, でしょう), which UniDic's pronunciations have;
  - Latin words through the English front end (misaki passes them through as letters).
- **Mandarin** (`zh.rs`, `num_zh.rs`): misaki's v1.0 `ZHG2P` path: cn2an-style numerals, its punctuation map, jieba (jieba-rs, MIT, the same dictionary and HMM) words, pypinyin's `lazy_pinyin` (whole phrase, else its strict forward maximum match over the phrase table, else per character; tables exported from pypinyin, MIT), misaki's pinyin-to-IPA table with tone arrows. No tone sandhi, as v1.0. Latin words through the English front end (v1.0 passed them through as raw letters, which Kokoro then reads as phoneme symbols).

### Parity with Python misaki (`scripts/kokoro-g2p-compare.py`, `cases/kokoro-g2p.tsv`: 25 en, 20 ja, 20 zh assistant lines)

| | identical lines | phoneme error rate vs misaki |
| --- | --- | --- |
| English | 19/25 | 1.5 % |
| Japanese | 0/20 | 7.2 % |
| Mandarin | 19/20 | 0.9 % |

- English mismatches: unknown names (g2p_en vs espeak-ng: Priyanka, Joaquín, Siobhan), "read" past tense after "I" (spaCy tags it VBD), "sign in" (spaCy's particle "in" stressed), and misaki itself garbling "8:15" and "10:05" (the clock-time reading fixes those).
- Japanese: every line differs because misaki drops all punctuation (above). The rest are dictionary differences: UniDic splits words differently (spacing), and either dictionary reads some words differently (NAIST: 明日 あした, 木曜日 もくようび, 15分 ふん, all correct; UniDic: いい as イー, 何か なんか). Neither is consistently better; the counters above fix most date/time readings.
- Mandarin: the one difference is the English word (above).

Front end time on the device (`straylight-listen --g2p`, the 65 lines): mean 2.9 ms (en), 1.8 ms (ja), 0.09 ms (zh) per sentence; the first English sentence 41 ms (g2p_en's network), the first Japanese one 16 ms (dictionary pages). Memory: English 15 MiB (the lexicon kept as its text with a sorted index; a hash map of strings was 57 MiB), Japanese 16 MiB and Mandarin 55 MiB (jieba), both loaded on first use and dropped after 10 minutes unused.

## Voices (task 2)

`work/kokoro-samples/` (git-ignored): every American female, Japanese female and Mandarin female voice, and blends, for a greeting, a calendar answer and a two-sentence reply; `work/kokoro-samples/INDEX.md` has the texts, hexgrad's grades, pitch, rate, ASR round trip, timbre similarity and notes (`scripts/kokoro-voices.py`, rendered by `scripts/kokoro-reference.py` with PyTorch on the laptop). From measurements and grades, not listening:

- **English: `af_heart`** (grade A, F0 197 Hz). Alternative `af_bella` (A-, closest timbre to af_heart).
- **Japanese: `jf_alpha*0.7+af_heart*0.3`** (style vectors interpolated); plain `jf_alpha` is the only adult, non-storybook jf voice. The blend lowers its F0 (271 to 246 Hz) and moves its timbre toward af_heart (cosine 0.41 to 0.62) with no loss in the ASR round trip.
- **Mandarin: `zf_xiaoni*0.7+af_heart*0.3`**; zf_xiaoni is the zf voice closest in timbre to af_heart (0.47), and the blend also removed its two tone slips (ASR CER 3.2 % to 0).
- Closest in timbre to af_heart: zf_xiaoni for Mandarin, jf_alpha for Japanese (jf_tebukuro scores slightly higher but is childlike).

These are the installed defaults, changeable in `/etc/straylight-listen.conf` (`--tts-voice ja=jf_alpha`, ...).

## On the device: straylight-listen

Installed by straylight-voice `listen/packaging/install.sh` (commit `1c9ca58`), enabled and running. Design and flow: straylight-voice `listen/README.md`, "Speech output". In short:

- The streamed reply is cut into clauses and sentences (`split.rs`; the first piece short: a clause, at most 44 characters in English, or a Japanese break after a particle or ので/から), each synthesised in order on the "tts" thread while earlier pieces play on "tts-play": 24 to 48 kHz (polyphase Kaiser FIR, -80 dB), mono to stereo, S16_LE to `hw:0,0`, 20 ms periods, 80 ms buffer, the PCM opened per reply and closed after it (silence between pieces).
- `spoken_chars`: grapheme clusters, about 30 Hz, from the sample being played (device delay subtracted), interpolated through the per-token durations (English: per word over that word's phonemes; Japanese and Mandarin: over the speaking time without pauses), never backwards. `level` from the output at the playback position.
- stop/cancel: the PCM is dropped, the running ONNX Runtime run terminated, queued pieces dropped. Measured with `--say-stop-ms`: 2-17 ms from the stop to the stream closed.
- The tablet's own voice cannot wake it (the detector fires only from Idle) and the wake word stays off 1.5 s after speech. Barge-in needs echo cancellation first (future work; the playback signal is in the same process for it).
- Offline speaks "I can't reach ai& right now." (ja/zh too); it and the not-signed-in prompt and the ai& error lines are synthesised once while idle and kept in `/var/lib/straylight-listen/tts-cache/`.
- Volume: the amplifier's shared setting (never above 207); speech is written at full digital scale, never boosted.
- Voices and pronunciations are configurable (`/etc/straylight-listen.conf`: `--tts-voice L=V`; `/etc/straylight-listen.d/lexicon.tsv`). The company name's pronunciation is an override in straylight-voice `listen/tts/lexicon.tsv` (samples for choosing it: `work/kokoro-samples/brand/`, git-ignored). Kokoro reads the symbol ʔ as a t.

### Device performance (task 3)

`--say-file` with the pacing sink (no sound; `scripts/device-kokoro.sh run ... --say-file bench-say.tsv --tts-device pace`), uint8, 6 threads, the service running alongside. Lines `*-cal` and `*-two` are 1-2 sentences, `*-3` three. "Gaps" is the silence a listener hears between pieces.

| Line | Audio | First audio | RTF | Gaps | Peak RSS (TTS process) |
| --- | --- | --- | --- | --- | --- |
| en-cal (1 sentence) | 6.9 s | 11.7 s | 2.96 | 5.0 s | 501 MiB |
| en-two | 6.8 s | 11.9 s | 2.94 | 4.1 s | 501 MiB |
| en-3 | 11.2 s | 4.8 s | 3.02 | 20.6 s | 535 MiB |
| ja-cal (1 sentence) | 8.5 s | 5.9 s | 2.96 | 14.1 s | 557 MiB |
| ja-two | 8.9 s | 6.1 s | 2.95 | 14.6 s | 561 MiB |
| ja-3 | 13.3 s | 6.2 s | 2.97 | 22.8 s | 564 MiB |
| zh-cal (1 sentence) | 9.1 s | 14.7 s | 2.92 | 7.0 s | 577 MiB |
| zh-two | 8.5 s | 13.9 s | 2.91 | 6.2 s | 579 MiB |
| zh-3 | 12.7 s | 6.2 s | 2.94 | 21.1 s | 579 MiB |

(That run was before the memory changes below and before the first piece was cut shorter; the RSS column is the old figure.) First audio is about 3x the first piece's length plus 0.3 s. **Speech is not continuous**: each next piece takes 3x its length, so the reply comes clause by clause with about twice as much silence as speech. The total time is about 3x the audio regardless of how it is cut; short pieces only move the pauses to clause boundaries.

Through the whole pipeline with live ai& replies (`scripts/device-kokoro-e2e.sh`: the demo requests from files, wake word, Qwen3-ASR with patch 0003, ai&, Kokoro, pacing sink, as a transient unit with the service's limits): first audio 6.9 s (en), 14.2 s (ja, one long sentence with no break; the particle rule now cuts it), 8.3 s (zh) after the reply's first text; RTF 2.95-3.04. Through the air (`scripts/device-kokoro-acoustic.sh`, amp held at 187 = -10 dB, then put back to the user's 207): the installed service answered aloud in English and Japanese.

Threads and CPU: 6 ORT threads at nice 5, spinning off. While a piece is synthesised the process uses about 4.8 cores (93 CPU-s over 19.5 s of synthesis); nothing when idle. Wake detector and capture while synthesising (utterance logs, live and file mode): longest audio-thread block 14-18.7 ms, none over 20 ms, no capture overrun, backlog at most 1 block.

### Memory over a full cycle

Changes after the first measurements (the service had reached 1.4-1.5 GiB RSS and the recogniser's pages had been reclaimed once, which made one request's decoder take 10.2 s instead of 2.3 s):
- English lexicon as text plus a sorted index: 57 to 15 MiB; Japanese and Mandarin data loaded lazily and dropped when unused: -71 MiB at rest.
- ONNX Runtime's arena shrunk after every run (`memory.enable_memory_arena_shrinkage`): without it the arena only grows with each new input length (395 to 479 MiB in two runs); with it the process returns to about 340 MiB after each run, no speed cost. Without an arena at all the transient peak is higher (810 MiB; a capped test scope was memcg-killed at 800 MiB, nothing else) and prepacking off is 25 % slower.
- The model file's page cache dropped after loading (posix_fadvise), so it is not charged to the unit.
- `MemoryLow=1500M` (was 1000M), so the whole working set, including the recogniser's memory-mapped pages, is protected; `MemoryMax=1600M` (was 1300M).

Full cycle, wake, captions, reply spoken, idle, for en, ja and zh in turn (`scripts/device-kokoro-e2e.sh cycle`, RSS sampled every 0.5 s): RSS 935 MiB before the synthesiser loads, 1253-1310 MiB through the cycle (max 1362), of which RssFile (the recogniser's model) 530-568 MiB throughout; major faults 13 at start and still 13 at the end (no page re-read; each request's decoder 2.0-2.3 s, as before); MemAvailable 1223 MiB before, at least 815 MiB during. No OOM kill of anything (kernel log), cgroup `memory.events` all zero.

## For the image (`rootfs/scripts/`, not changed here)

Updated 2026-11-01 for the real-time voices (see [Real-time synthesis](#real-time-synthesis-matcha-tts-and-piper)).

1. Build: `listen/tts/build.sh aarch64` (clones `git@github.com:r9y9/open_jtalk.git` at `1e52154e` into straylight-voice `downloads/`), `listen/tts/stage.sh`, then `scripts/build-aarch64.sh --release --manifest-path listen/Cargo.toml --features asr,tts`. `stage.sh` needs:
   - `KOKORO_ONNX_DIR` = onnx-community/Kokoro-82M-v1.0-ONNX at `1939ad2a`;
   - `PYTHON` with onnx, misaki[en,ja,zh] 0.9.4, g2p_en, pypinyin (table export, durations outputs);
   - `ORT_LIB` = sherpa-onnx v2.0.1 linux-aarch64's `libonnxruntime.so` (ONNX Runtime 1.28.2);
   - `MATCHA_DIR` = sherpa-onnx `tts-models/matcha-icefall-en_US-ljspeech` (model-steps-3.onnx, tokens.txt), `VOCOS` = sherpa-onnx `vocoder-models/vocos-22khz-univ.onnx`;
   - `ORT_PYTHON` = a Python with onnxruntime 1.28.0 and onnx (writes the `.ort` files the runtime memory-maps; they must come from the runtime's version);
   - not for the image: `PIPER_VOICES` (the Mandarin Piper voice is not cleared for shipping, see the licence notes below).
2. Overlay, in addition to the voice-pipeline list:
   - `usr/local/lib/straylight-listen/libonnxruntime.so` (35 MB);
   - `usr/local/share/straylight-listen/matcha/ljspeech/` (model.onnx 74 MB, model.ort 64 MB, vocos.onnx 54 MB, vocos.ort 54 MB, tokens.txt): the English voice;
   - `usr/local/share/straylight-listen/kokoro-v1.0-uint8.onnx` (170 MB) and `kokoro-v1.0-uint8.ort` (170 MB), `voices/` (af_*, jf_*, zf_*: 9.5 MB): Japanese and Mandarin (Kokoro stays selectable for every language);
   - `usr/local/share/straylight-listen/tts/` (en-us.lex, en-extra.lex, g2p-en.bin, zh-*.tsv, ja-words.txt, lexicon.tsv, open_jtalk_dic/ with its COPYING: 81 MB);
   - `etc/systemd/system/straylight-listen.service` (unchanged: MemoryMax 1600M, MemoryLow 1500M) and `etc/straylight-listen.conf` (new speech section).
   
   Checksums: `out/listen/tts-share/SHA256SUMS`. About +700 MB on root (was +296 MB). The `.onnx` files are kept next to the `.ort` files for `--tts-memory none` and as the source; dropping the four `.onnx` (Kokoro, Matcha, Vocos) saves 300 MB if the default memory setting is kept.
3. Optional: `etc/straylight-listen.d/lexicon.tsv` for local pronunciations.
4. No new packages (alsa-lib is already needed; ONNX Runtime is the shipped .so; no espeak-ng).
5. `/var/lib/straylight-listen/tts-cache/` is made by the service (its state directory). Its keys change with the engine, so the cached fixed lines are made again once after the update.

## Licences

- Kokoro-82M v1.0, model and voices: Apache-2.0 (hexgrad). onnx-community's ONNX export: Apache-2.0.
- ONNX Runtime: MIT. `ort` crate: MIT or Apache-2.0. jieba-rs: MIT. unicode-normalization, unicode-segmentation: MIT or Apache-2.0.
- misaki (the ported code, the gold/silver lexicons, ja_words.txt): Apache-2.0; its cutlet code is from polm/cutlet (MIT), its pinyin-to-IPA from pinyin-to-ipa (MIT), cn2an's rules (MIT).
- g2p_en and its network: Apache-2.0 (trained on CMUdict, BSD-2-Clause).
- Open JTalk's MeCab and the NAIST Japanese Dictionary: BSD 3-clause.
- pypinyin's tables, jieba's dictionary: MIT.
- espeak-ng (GPL-3.0) is not used or shipped: g2p_en replaces misaki's espeak fallback, so no GPL code runs in the listener and no out-of-process GPL program is needed. UniDic (for the Python reference only) is not shipped.

## Scripts (Kokoro)

| Script | What |
| --- | --- |
| `scripts/kokoro-onnx-durations.py` | add the durations output to an onnx-community export |
| `scripts/kokoro-frontend-data.py` | export the front-end tables (misaki, g2p_en, pypinyin) |
| `scripts/kokoro-reference.py` | Python misaki phonemes, PyTorch renders (laptop) |
| `scripts/kokoro-g2p-compare.py` | our phonemes against misaki's |
| `scripts/kokoro-profile.py` | ONNX Runtime profile by module |
| `scripts/kokoro-asr-check.py` | ASR round trip of rendered lines |
| `scripts/kokoro-voices.py` | voice measurements for the samples INDEX |
| `scripts/device-kokoro.sh push\|run\|pull\|clean` | payload and capped, detached runs on the tablet |
| `scripts/device-kokoro-e2e.sh TAG WAV...` | the whole pipeline from files, with memory sampling |
| `scripts/device-kokoro-acoustic.sh TAG CLIP` | one request through the air at amp 187 |
| `cases/kokoro-lines.tsv`, `cases/kokoro-g2p.tsv` | sample lines; front-end parity set |

Downloads (`downloads/`, git-ignored): `kokoro/` (both Hugging Face repos at the revisions above, SHA-256 checked against the LFS pointers), `kokoro-venv/` (kokoro 0.9.4, misaki 0.9.4, torch 2.8 CPU, UniDic 3.1.0, en_core_web_sm 3.8.0, onnxruntime 1.31.1), `nltk_data/`.

## Left on the device (Kokoro)

The installed listener with speech (above), enabled and running; `/usr/local/lib/straylight-listen/libonnxruntime.so`; Kokoro, voices and `tts/` under `/usr/local/share/straylight-listen/`; `/var/lib/straylight-listen/tts-cache/` (20 fixed-line pieces); the unit with MemoryMax 1600M / MemoryLow 1500M. The test payloads (`/var/tmp/kokoro`, `/var/tmp/kokoro-e2e`) were removed; the speaker amp is at the user's 207.

# Real-time synthesis: Matcha-TTS and Piper

Kokoro speaks clause by clause on this CPU (RTF 2.9-3.0), which the user found bad. This section surveys and measures lighter models, and integrates the ones that keep up. **Result: English is now continuous (Matcha-TTS + Vocos, RTF 0.41-0.50), and Mandarin is continuous with a Piper voice (RTF 0.42-0.47). That voice has a licence problem in its ancestry, so it is installed on this tablet for audition only, and the packaged default stays Kokoro. No Japanese model meets the brief:** none that is cleared for commercial use runs in real time here. Japanese stays on Kokoro (RTF 3.1).

Measured 2026-11-01 on the baseline kernel, 6 threads at nice 5, with straylight-listen running.

## Survey (late October 2026)

The vocoder sets the cost. Kokoro's iSTFTNet needs about 48 GFLOP per second of audio; MeloTTS and Piper's "high" voices use HiFi-GAN V1 (512 channels; MeloTTS at 44.1 kHz with an extra stage), about 50-55 GFLOP. Piper "medium" (HiFi-GAN with resblock 2, 256 channels) needs about 4 GFLOP, and Vocos (ConvNeXt on frames, then an inverse STFT) about 2. Candidates:

| Model | Languages | Architecture | Licence (code / weights / data) | Verdict |
| --- | --- | --- | --- | --- |
| Matcha-TTS (icefall) + Vocos | en (LJSpeech); zh Baker (NC), zh-en (data not stated) | flow matching, 3 steps; Vocos 22 kHz | MIT, Apache-2.0 / Apache-2.0 / LJ Speech PD; Vocos data LibriTTS-R, LJ, Catalan CC BY-SA | **English winner** |
| Piper (VITS medium) | en: kristin, ljspeech (from scratch, PD data); most other en_US voices fine-tuned from lessac (research-only data); ja: hi_fi_captain (CC BY-NC-SA); zh: huayan (unknown data, from lessac), xiao_ya (Baker, NC), chaowen (from xiao_ya); AISHELL-3 community voice (Apache data, from libritts_r ← lessac) | VITS, 22 kHz | MIT (piper1-gpl is GPL-3.0, not used) / per voice | English and Mandarin real time; licence clean only for kristin/ljspeech |
| Supertonic 3 (Supertone, 2026-04) | 31 languages incl. en, ja; **no zh** | text-to-latent flow matching + latent decoder, 44.1 kHz, raw text | MIT / OpenRAIL-M / not disclosed | not real time here |
| VOICEVOX CORE 0.17.1 | ja only | duration + intonation predictors, decoder at 24 kHz; own ONNX Runtime build, encrypted models | MIT core; ORT build and models under VOICEVOX terms (commercial OK with credit) | best accent, not real time here |
| MeloTTS | en, ja, zh (+es, fr, ko) | Bert-VITS2 style, HiFi-GAN V1 at 44.1 kHz + BERT | MIT / MIT / not disclosed | about as heavy as Kokoro |
| Kokoro-82M v1.0 | en, ja, zh | StyleTTS2 + iSTFTNet | Apache-2.0 | the baseline |
| KittenTTS 0.8 (nano/mini) | en only | StyleTTS2-derived | Apache-2.0 | slower than Piper (laptop) |
| piper-plus (MB-iSTFT-VITS2) | ja/en/zh/es/fr/pt in one model | very light decoder | MIT code; base trained on MOE-Speech (game/anime voices, unclear rights), Tsukuyomi corpus voice | rejected on data |
| icefall VITS AISHELL-3 | zh, 174 speakers | VITS, **8 kHz** | Apache-2.0 throughout, from scratch | the one clean real-time Mandarin model; low fidelity |
| MOSS-TTS-Nano, Pocket TTS, ZipVoice, NeuTTS, VibeVoice | | autoregressive / large | | too heavy for this CPU (not measured) |

Japanese corpora checked for a Piper/Matcha voice: JSUT (commercial use needs the authors' permission), JVS (non-commercial), Hi-Fi-CAPTAIN (CC BY-NC-SA), CSS10 (public domain, but only fine-tunes of the MOE-Speech base exist). None is ready to use.

## Measured on the tablet

`scripts/device-rt.sh` (sherpa-onnx v2.0.1's C API through `src/rt-bench.c`; ONNX Runtime 1.28; models in `/dev/shm`) and `src/vv-bench.c` (VOICEVOX C API), each run in a capped scope next to the service. Later rows: `scripts/device-rt-say.sh`, straylight-listen's own `--say-file` with the pacing sink, voices under the installed share. "1 sent." is the calendar line (5-7 s of audio), "3 sent." the 3-sentence reply (9-12 s). First audio for the bench rows means the whole first sentence, without any cutting.

| Model | Lang | RTF 1 sent. | RTF 3 sent. | First audio | Peak RSS | Licence |
| --- | --- | --- | --- | --- | --- | --- |
| Piper kristin medium (sherpa) | en | 0.42-0.43 (4 thr: 0.50-0.52) | 0.42-0.43 | 2.2-2.3 s (1 sent.), 0.36-0.40 s (3 sent.) | 283 MiB | clean |
| Matcha LJSpeech + Vocos (sherpa) | en | 0.39 | 0.42 | 1.55 s, 1.18 s | 235 MiB | clean |
| Supertonic 3 int8, 3 / 5 steps | en | 1.56 / 2.42 | 1.53 / 2.45 | 10.6 s | 324-348 MiB | OpenRAIL-M, data not disclosed |
| Supertonic 3 int8, 3 / 5 steps | ja | 1.51 / 2.43 | 1.45 / 2.28 | 10.4 s | 331-344 MiB | |
| Supertonic 3 fp32, 2 / 3 steps | ja | 1.12 / 1.56 | 1.12 / 1.53 | 7.8 s | 509-515 MiB | |
| VOICEVOX 冥鳴ひまり, 6 / 4 threads | ja | 2.85 / 3.59 | 2.96 / 3.74 | 17.9 s (1 sent.), 4.4 s (3 sent., per sentence) | 337-345 MiB | VOICEVOX terms |
| **Matcha + Vocos (straylight-listen)** | en | 0.41-0.44 | 0.45-0.48 | 1.4-1.5 s (paced, whole reply at once) | see memory | clean |
| **Piper AISHELL-3 SSB0534 (straylight-listen)** | zh | 0.43-0.44 | 0.42-0.44 | 2.0 s (1 sent.), 0.7 s (3 sent.) | see memory | lessac ancestry |
| Kokoro uint8 (straylight-listen, baseline) | en | 2.95-3.08 | 3.04-3.13 | 9.2-9.6 s | 438-464 MiB | Apache-2.0 |
| MeloTTS zh_en | | not run: one laptop thread costs 0.80 s per second of audio, 8x Piper's (0.10) and above Kokoro's 0.69 | | | | MIT, data not disclosed |
| icefall VITS AISHELL-3 | zh | not run: laptop 0.053 per second of audio, about 0.23 here | | | | clean, 8 kHz |

Laptop single-thread cost per second of audio (`scripts/rt-laptop-cost.py`, en 3-sentence line): Matcha 0.094, Piper kristin 0.102, ljspeech 0.107, Supertonic int8 0.195 (3 steps) / 0.292 (5), Kitten nano int8 0.330, mini 0.776, MeloTTS 0.797, Kokoro uint8 0.690. The device's ratio to that is roughly 4.3x (Kokoro), with fp32 models a little better.

Wake detector and capture during the bench and say runs (the service's 10-minute stats): longest block 8.8-16.0 ms, none over 20 ms, backlog at most 2, no xruns. In the live runs below, with the recogniser, ai& and synthesis in one process: one block of 20-29.5 ms per request, no xruns.

### Memory (TTS part of the process; en Matcha and zh Piper resident; device)

| `--tts-memory` | At rest: anon / file | Peak (HWM) | RTF en / zh |
| --- | --- | --- | --- |
| none (ORT defaults) | 379 / 21 MiB | 489 MiB | 0.41-0.45 / 0.42-0.43 |
| mmap (`.ort` memory-mapped, weights used in place) | 214 / 198 | 518 | 0.44-0.48 / 0.44 |
| mmap,noprepack | 145 / 212 | 450 | 0.48-0.51 / 0.43 |
| Kokoro alone, none (as installed before) | 342 / 19 | 438 | 2.95-3.04 |
| Kokoro alone, mmap | 209 / 191 | 464 | 3.08-3.13 |
| Kokoro alone, mmap,noprepack | 54 / 193 | 341 | 4.13-4.51 |

- The anonymous memory was ONNX Runtime's copy of the initializers plus prepacking's second, reordered copy. The `.ort` format with `session.use_ort_model_bytes_directly` and `..._for_initializers` over a private read-only mmap (`src/tts/ort_session.rs`) turns the first into clean file pages; turning prepacking off removes the second. Prepacking only buys speed for Matcha (10 %) and Kokoro (30-50 %), so the default is `mmap,noprepack,prepack:matcha,prepack:kokoro`.
- The arena is shrunk after every run, as before. Disabling it (`noarena`) hung on the laptop and was not pursued. The thread pool is per session (one synthesis at a time, 6 threads, not spinning).
- The service with this default: at rest 1.37 GiB RSS, of which 600 MiB anonymous and 770 MiB file-backed (560 MiB of that is the recogniser's model). After a Japanese reply, with Kokoro loaded, it is 1.39-1.56 GiB for 10 minutes. Over the live runs MemAvailable stayed at 790 MiB or more; it was at least 815 with Kokoro in all three languages. Without TTS the process is at about 940 MiB, so TTS adds about 430 MiB at rest, of which about 220 MiB is anonymous. Kokoro alone added 340 MiB at rest, almost all of it anonymous.
- ggml instead of ONNX Runtime would save the 35 MB runtime library and use GGUF weights in place (no prepack copies at all). But ggml's convolutions go through im2col (the NanoCodec lesson in the Magpie section), and these models are mostly 1-D convolutions, so it would probably be slower. Not tried.

### Live, through the whole pipeline (`scripts/device-rt-e2e.sh`; the demo requests, real ai& replies; the service stopped for about 2 minutes per run)

| Lang | Synthesiser | Pieces | Audio | RTF | First audio after the reply's first text | Silence between pieces |
| --- | --- | --- | --- | --- | --- | --- |
| en | Matcha | 2 | 7.4 s | 0.50 | 2.2 s (first piece 50 characters, no clause mark; Kokoro was loading for the prewarm at the same time) | 0.0 s |
| zh | Piper AISHELL-3 | 3 | 9.0 s | 0.47 | 1.36 s | 0.0 s |
| ja | Kokoro (with prepacking) | 2 | 6.9 s | 3.15 | 12.3 s | 5.9 s |
| ja | Kokoro (no prepacking, first try) | 3 | 10.0 s | 4.65 | 16.2 s | 24.8 s |

English's first audio missed the 1.5 s target, so the splitter's first Latin-script piece is now at most 32 characters (was 44), with later pieces doubling (64, 128, 220) so that each is ready before the previous one ends. See [After the splitter change](#after-the-splitter-change).

## Integration (straylight-voice `listen/src/tts/`, commit `a6c745b`)

- One synthesiser per language, `--tts-voice L=ENGINE:VOICE`: `matcha:ljspeech`, `piper:NAME#SPEAKER`, `kokoro:VOICE` (a bare name means Kokoro, so old configs keep working). `--tts-keep L,L` (default en,zh) sets which load at start; the others load on first use and are dropped after 10 minutes, so Kokoro costs nothing unless Japanese is spoken. Kokoro stays selectable for every language, which is also where the kokoro-gpu backend can slot in.
- `matcha.rs`: icefall's acoustic model (input `_ ^ _ p1 _ … $ _`, as sherpa-onnx builds it), then Vocos (`mag`, `x`, `y`), then an inverse STFT in Rust (`dsp.rs`: n_fft 1024, hop 256, Hann, centred).
- `piper.rs`: Piper ONNX voices, espeak-style phonemes (`^ _ p _ … $`) or the pinyin scheme of Piper's Chinese phonemizer (initial or Ø, final, tone, pad). The speaker comes from the voice's json.
- Front end: the existing misaki port, rewritten into espeak-ng's en-us notation (`g2p/espeak.rs`: A/I/W/Y/O to eɪ/aɪ/aʊ/ɔɪ/oʊ, ʤ/ʧ, T to ɾ, ɜɹ/əɹ/ɔɹ/ɑɹ to ɜː/ɚ/ɔːɹ/ɑːɹ, the length marks on tense vowels). Mandarin uses its pinyin before the IPA step (`Zh::pinyin`); Latin letters inside Mandarin are read as Mandarin letter names. No espeak-ng anywhere.
- Durations: `scripts/piper-onnx-durations.py` adds the `/Ceil` node's output ("durations") to the Piper and Matcha graphs. Each symbol's frames (256 samples) drive `spoken_chars` as before (English per word, others over the speaking time).
- Output: a rational Kaiser-sinc resampler (`dsp.rs`, 22.05 to 48 kHz, unity gain, zero phase per piece); Kokoro keeps its 2x polyphase filter.
- Lexicon: the shipped English brand pronunciation is now h5, `ˌAˌIˈæːnd` (the espeak voices get `ˌeɪˌaɪˈæːnd`). ASR round trip: "AI End" (Kokoro, Piper kristin) and "AIAN" (Matcha), CER 4.9-7.3 % on the brand line. ja エーアイアンド and zh 诶爱安德 are unchanged; zh Straylight is 斯特雷莱特 (new).
- Stop/cancel uses the same run-options terminate flag for every engine. Laptop measurement: stream closed 3.2-10.9 ms after the stop.
- The fixed-line cache key now includes the engine and voice.

## Options not taken (effort estimates)

- **Kokoro's acoustic model with a new, light vocoder.** No ready-made one exists: Kokoro's decoder takes its own aligned text features plus F0 and energy curves, not a mel spectrogram, so no Vocos or HiFi-GAN checkpoint fits. Distilling a Vocos/iSTFT-class decoder means generating 20-50 h of Kokoro intermediates and audio (a GPU, a few hours), then training 1-2 days on a 24 GB GPU (the laptop's 4 GB is too small), plus about a week of engineering and checks. It would keep Kokoro's voices and blends in all three languages, Japanese included, at an estimated RTF of about 0.3. **This is the route to one voice family that is real time.**
- **Voices distilled from Kokoro** (Matcha or Piper trained on Kokoro's own output, which Apache-2.0 allows): 10-20 h per language, 1-2 days of training per language on a 24 GB GPU. That would give a clean, real-time Japanese voice and a Mandarin Piper voice without the lessac ancestry. Its prosody would be at best Kokoro's.
- **A Mandarin Piper voice from scratch on AISHELL-3**, or warm-started from the public-domain kristin/ljspeech checkpoints if they can be had: 2-4 GPU-days. That would clean up the zh licence chain.
- **VOICEVOX in streaming mode** (`create_audio_feature` + `render` slices) would shorten first audio, but at RTF 3 the gaps stay.

## Scripts (real-time synthesis)

| Script | What |
| --- | --- |
| `scripts/rt-laptop-cost.py` | one-thread laptop cost of every candidate (ranking before device runs) |
| `src/rt-bench.c`, `scripts/device-rt.sh base\|model\|run\|clean` | sherpa-onnx C API bench (Piper, Matcha, Kitten, Supertonic, lexicon VITS) on the tablet, locked, capped, detached |
| `src/vv-bench.c` | VOICEVOX CORE C API bench (per sentence: analysis, then synthesis) |
| `scripts/rt-espeak-lexicon.py` | per-word espeak lexicon for sherpa's CLI (abandoned: sherpa 2.x's lexicon path garbles Piper input) |
| `scripts/rt-render.py`, `scripts/rt-render-melo.py` | laptop renders for the samples (Piper/Matcha from our front end's symbols, Supertonic, sherpa VITS, VOICEVOX; MeloTTS) |
| `scripts/rt-asr.py` | ASR round trip and median F0 of sample folders |
| `scripts/rt-accent.py`, `cases/ja-accent.tsv` | Japanese pitch-accent minimal pairs |
| `scripts/device-rt-say.sh push\|run\|stats` | straylight-listen `--say-file` on the tablet next to the service, and the service's stats lines |
| `scripts/device-rt-e2e.sh TAG WAV...` | the whole pipeline with live ai& replies (as `device-kokoro-e2e.sh`) |
| `cases/rt-lines.tsv` | the sample lines (Kokoro's plus the brand line) |
| straylight-voice `listen/scripts/piper-onnx-durations.py` | durations output for Piper and Matcha graphs |

Samples: `work/rt-samples/<model>/<voice>-<lang>-<line>.wav`, with `INDEX.md` (fit, licence, ASR, accent, VOICEVOX terms). Downloads (`downloads/rt/`, git-ignored, sha256 in `downloads/rt/SHA256SUMS.sherpa`, `downloads/rt/voicevox/SHA256SUMS`, Piper voices from `rhasspy/piper-voices` at the revision in `downloads/rt/piper/REVISION`, the AISHELL-3 voice at `be77d1b1`, Supertonic 3 at `3cadd1ee`): sherpa-onnx model packages, Piper voices, VOICEVOX 0.17.1, Supertonic 3, MeloTTS (`rt/melo-src`, `melo-venv`), `rt-venv` (sherpa-onnx 2.0.1, onnxruntime, phonemizer + espeakng-loader, used only on the laptop for the cost ranking), `ort128-venv` (onnxruntime 1.28.0 for `.ort` conversion).

## Left on the device (real-time synthesis)

- straylight-listen as built from this work, enabled and running.
- In `/usr/local/share/straylight-listen/`: `matcha/ljspeech/`, `piper/zh_CN-cn_aishell3-medium.{onnx,onnx.json,ort}`, `kokoro-v1.0-uint8.ort`, and the new `tts/lexicon.tsv`.
- `/etc/straylight-listen.conf` has `--tts-voice zh=piper:zh_CN-cn_aishell3-medium#SSB0534`, for audition (interim: remove it to go back to Kokoro for Mandarin).
- Test payloads (`/var/tmp/rt`, `/dev/shm/rt`, `/var/tmp/rt-e2e`) removed; the Piper kristin test voice removed from the share.

### After the splitter change

`scripts/device-rt-say.sh` with the committed build (`a6c745b`), English, paced, the whole reply given at once, the service running:

| Line | Pieces | Audio | RTF | First audio | Silence between pieces |
| --- | --- | --- | --- | --- | --- |
| the live reply's text ("I don't have live weather data and I can't access the internet, …"; 2 sentences) | 4 | 11.6 s | 0.47 | 1.47 s (was 2.2 s live) | 0.00 s |
| en-cal (1 sentence) | 3 | 7.2 s | 0.47 | 1.14 s | 0.00 s |
| en-3 (3 sentences) | 5 | 11.0 s | 0.48 | 0.61 s | 0.18 s |
| en-brand | 2 | 4.5 s | 0.47 | 0.88 s | 0.00 s |

The same binary was then installed and the service restarted (speech ready 35 s after the restart; MemAvailable 1004 MiB at rest).
