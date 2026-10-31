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
