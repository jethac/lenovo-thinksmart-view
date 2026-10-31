# On-device speech recognition

Qwen3-ASR-0.6B on the ThinkSmart View, for short voice commands to a chatbot in English, Japanese and Mandarin. Recognition and synthesis run on the device; the chatbot's text inference runs on ai&'s servers (`GOAL.md`).

## Setup

- Runtime: [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) at `5700f127e38dd53c4735ea23ef743b4b538eacd4`, statically cross-built for Cortex-A53 (`scripts/build-transcribe.sh`, `-mcpu=cortex-a53`, NEON, no dotprod), plus `patches/0001-qwen3_asr-quantized-conv-stem.patch`, `patches/0002-qwen3_asr-incremental-conv-stem.patch` and `patches/0003-qwen3_asr-prompt-prefix-cache.patch` (apply in order with `git apply`; the measurements before the section "Reusing the decoder prompt between phrases" are without 0003).
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

## Phrase by phrase

Text a phrase at a time while the user is still speaking, with Qwen3-ASR only: Silero VAD cuts the incoming audio at short pauses, and each phrase is transcribed on its own as soon as it ends, while the next one is still being spoken. The final transcript is the joined phrases.

### Program

`phrase/phrase-stream.cpp`, built by `phrase/build.sh [a53|native]` (into `work/build-phrase-a53` or `work/build-phrase-native`). It links transcribe.cpp as a library through its public API only (`include/transcribe.h`, `include/transcribe/vad.h`). The build uses its own snapshot of the pinned commit (`git archive` into `work/phrase-src/`, plus `patches/*.patch` applied with `patch`), so work in progress in `downloads/transcribe.cpp` does not reach it.

- Models: `Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf` and `silero-vad-v6.2-F32.gguf` (`handy-computer/silero-vad-v6.2-gguf`, 1.2 MB, sha256 checked, in `downloads/models/silero-vad-v6.2/`). transcribe.cpp has Silero built in (`--vad-threshold` in the CLI is that model), with a streaming API that returns one speech probability per 32 ms frame, so no onnxruntime or sherpa-onnx is needed. Both models stay loaded for the life of the process; one ASR session and one VAD session (1 thread) are reused for every phrase and utterance, after a warm-up run.
- Feeding: 20 ms slices, each handed over when it would have finished arriving from a microphone (`sleep_until` on an absolute schedule; `--no-realtime` feeds as fast as possible). The feeding thread runs the VAD and the segmenter; a worker thread transcribes phrases from a queue in order.
- Segmenter (Silero `get_speech_timestamps` logic on streamed probabilities): speech starts at p >= 0.5; inside speech, p < 0.35 starts a pause. A pause of `--min-pause` 300 ms ends the phrase, if the phrase has at least `--min-phrase` 1000 ms of audio; a shorter phrase waits for the next pause and is merged with what follows, unless the pause reaches `--long-pause` 800 ms. A phrase reaching `--max-phrase` 6000 ms (below the encoder's 8 s attention window) is split at the frame with the lowest speech probability in its second half, and the rest continues as the next phrase. `--pad` 200 ms of audio is kept before and after each phrase (never overlapping the previous phrase). Phrases with less than 250 ms of speech are dropped as noise.
- Transcription: `transcribe_run` on the phrase's audio with `language = NULL` (the model detects the language per phrase; `transcribe_detected_language` is recorded) and the text so far as context (`transcribe_run_params::prompt`, `--context`: -1 all, 0 none, N last N bytes). Phrase texts are joined with a space only between two Latin-script ends.
- Output: one JSON line per input WAV on stdout: per phrase its audio span, VAD speech end, whether it was a forced split, the times the cut was made, transcription started and text was ready (ms from the start of the audio), mel/encode/decode times, context bytes, language and text; the joined text; feed lateness, process CPU time during the audio and in total, ASR busy time, peak RSS; and with the default `--offline`, a whole-utterance `transcribe_run` of the same audio afterwards (today's path) for comparison. Each phrase text is also printed to stderr the moment it is ready.

Not available through the public API (worked around or left out, not patched):
- Qwen3-ASR does not have `TRANSCRIPT_PREFIX` (`--prefix` is an error for this family, `docs/prompting.md`); it has `CONTEXT_PROMPT` (`--prompt`), which puts the text in the system message. That is what is used. A transcript prefix would not fit anyway: it requires the audio to contain the prefix's speech.
- No way to keep the KV cache of the prompt between runs: the chat frame (15 tokens) and the context are prefilled again for every phrase, at about 34 ms per token on this CPU. The context comes before the audio in the prompt, so a cached, growing system-message prefix would remove most of its cost. (Now `patches/0003`, section "Reusing the decoder prompt between phrases".)
- No way to restrict language detection to a set (en/ja/zh); no per-run thread count; Qwen3-ASR does not report `supports_spec_decode`, so `spec_k_drafts` has no effect for it.
- At most one run in flight per model: a phrase cannot be encoded while the previous phrase is still decoding unless a second model instance is loaded (another ~600 MB).

### Test utterances

`scripts/make-phraseset.py` writes 33 utterances to `work/testset/phrase/` (`refs.tsv` for `score.py`, `parts.tsv` with each part's language, span and reference):
- en 1-4, ja 1-7, zh 1-5: 2-4 clips of the command sets (edges trimmed to speech) joined with 300-700 ms gaps of low-level brown noise (-54 dBFS, not digital silence); 8.7-16.8 s.
- mx 1-8: the same, mixing languages (en+ja, ja+en, en+zh, zh+en, en+ja+en, zh+ja, ja+zh, en+zh+en); 8.4-14.0 s.
- lx-en/ja/zh 1-3: single 12-18 s LibriSpeech test-clean and FLEURS clips with their natural pauses.

Every clip is brought to a speech level of -22 dBFS first (as a microphone AGC would): four of the FLEURS Japanese clips sit at about -55 dBFS, at the level of the added noise, and Silero gave them speech probabilities of 0.2-0.4. With levelled audio, VAD thresholds 0.5 and 0.35 and pauses of 250-500 ms all cut at every clip boundary (no phrase spans two clips); longer pauses give fewer cuts inside the long clips and more forced splits.

Run on the device with `scripts/device-phrase.sh TAG [options]` (under the lock, `/dev/shm`, cleaned up), summarise with `scripts/phrase-summary.py RESULTS.jsonl [--per-utt]`.

### Results on the device

Defaults above (300 ms pause, 200 ms padding, full context), 8 threads, real-time feeding, 2026-10-31. Medians over utterances; caption lag over phrases. Caption lag = end of the phrase's speech (VAD) to its text. End wait = end of the last speech (offline VAD over the clip, unpadded) to the final text; offline wait = the same 300 ms of silence it needs to know the speech ended + whole-utterance transcription. Accuracy is corpus-level (WER for English, CER otherwise; mixed utterances as CER).

| Set | Utts | Audio | Phrases | Phrase length | Caption lag | First phrase lag | End wait, phrases | End wait, offline | Phrase-joined | Offline |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| en | 4 | 12.2 s | 4 | 2.4 s | 6.61 s | 4.51 s | **9.11 s** | 16.67 s | WER 2.08 % | WER 2.08 % |
| ja | 7 | 15.7 s | 2 | 3.5 s | 7.18 s | 7.54 s | **7.87 s** | 19.19 s | CER 9.79 % | CER 7.72 % |
| zh | 5 | 15.5 s | 3 | 3.7 s | 7.75 s | 6.20 s | **9.77 s** | 20.85 s | CER 3.36 % | CER 2.24 % |
| mixed | 8 | 11.8 s | 2 | 3.0 s | 6.86 s | 4.98 s | **7.56 s** | 14.98 s | **CER 4.77 %** | CER 18.14 % |
| long en | 3 | 17.8 s | 4 | 3.4 s | 12.55 s | 9.04 s | **18.66 s** | 23.57 s | WER 3.36 % | WER 1.68 % |
| long ja | 3 | 14.3 s | 2 | 3.9 s | 10.65 s | 8.97 s | **12.39 s** | 18.75 s | CER 18.79 % | CER 18.12 % |
| long zh | 3 | 15.2 s | 3 | 3.2 s | 8.76 s | 7.05 s | **12.56 s** | 19.18 s | CER 6.45 % | CER 5.65 % |

Mixed utterances scored per part (each phrase assigned to the part it overlaps most): English WER 1.89 %, Japanese/Mandarin CER 9.60 %.

Keeping up. Each phrase costs about 1.8 x its audio (encoder ~0.5 x, decoder the rest), against 1.3-1.6 x for whole clips offline: every phrase pays the chat-frame prefill again and decodes its own `language X<asr_text>` header (~4 steps of 100 ms). So processing does not keep up with continuous speech; the pauses absorb part of it, and the queue grows over an utterance:

| Phrase in utterance | Phrases | Caption lag | Waiting in queue | Transcription | Transcription / audio |
| --- | --- | --- | --- | --- | --- |
| 1st | 33 | 6.32 s | 0.00 s | 5.98 s | 1.67 |
| 2nd | 33 | 7.87 s | 1.06 s | 6.19 s | 1.79 |
| 3rd | 19 | 9.54 s | 3.22 s | 5.72 s | 1.93 |
| 4th | 6 | 11.83 s | 6.59 s | 5.08 s | 2.14 |
| 5th | 1 | 18.79 s | 13.15 s | 5.31 s | 2.42 |

The ratio is worse for short phrases (1-2 s: 2.1 x; 5-6 s: 1.5 x). Total ASR compute over all phrases is 0.90 x that of the whole-utterance run (the offline run also encodes the pauses and attends over the whole utterance), so splitting costs nothing in total work; the end-of-speech wait is shorter only because most of the work is done during the speech. With 4+ phrases (long English monologues) the backlog at the end of speech is most of the wait.

Load while the user speaks: the process uses 62 % of the 8 cores on average during the audio (the ASR worker is busy 63 % of the time and ggml's threads busy-wait while it is); between phrases it is idle apart from VAD. The feeding/VAD thread was never more than 41 ms late against the real-time schedule with all 8 ASR threads busy. Peak RSS 1485 MiB, which includes the whole-utterance comparison run of up to 18 s; the phrase path alone was not measured separately (the model loaded is 925 MiB; a 7 s clip offline peaks at 1087 MiB, and phrases are at most 6 s). The device warmed from 36 to 54 °C over the 25 min run, with no throttling.

Language detection: the language is right for every phrase in every set (19 of 19 phrases in the mixed utterances, 92 of 92 in total). The whole-utterance run picks one language for a mixed utterance (ja or zh in all 8) and writes the other language's speech in it, e.g. `what already here they said to her。軍刀や湖水では…` or, on the laptop, an English "translation" of the Japanese part; that is where its 18 % CER comes from. For code-switching, phrase splitting is much more accurate than the whole-utterance path.

Where splitting costs accuracy (long clips): words at a cut are lost or changed (`of fair complexion` -> `A fair complexion`; `并配以` -> `并配`; a forced split in the middle of `観測できるように`), and each phrase is punctuated as a sentence. Within a phrase the transcripts are the same as offline.

### Padding and context (laptop, accuracy only)

Same segmentation, transcripts from the native build (`--no-realtime`); timing on the laptop is not meaningful.

| Set | Pad 200 ms | Pad 300 ms | Pad 400 ms | Pad 200 ms, no context | Offline |
| --- | --- | --- | --- | --- | --- |
| en | WER 2.08 % | WER 2.08 % | WER 2.08 % | WER 2.08 % | WER 2.08 % |
| ja | CER 8.61 % | CER 8.01 % | CER 8.61 % | CER 9.20 % | CER 7.12 % |
| zh | CER 3.36 % | CER 2.61 % | CER 2.24 % | CER 3.36 % | CER 2.24 % |
| mixed | CER 5.49 % | CER 4.53 % | CER 3.58 % | CER 5.01 % | CER 26.97 % |
| long en | WER 4.20 % | WER 4.20 % | WER 4.20 % | WER 5.04 % | WER 1.68 % |
| long ja | CER 20.81 % | CER 21.48 % | CER 22.82 % | CER 20.13 % | CER 20.81 % |
| long zh | CER 6.45 % | CER 8.87 % | CER 6.45 % | CER 8.06 % | CER 4.84 % |

- Padding: no consistent effect between 200 and 400 ms (differences of one or two characters per set; the sets are small). 200 ms is kept, as it adds the least audio per phrase. The post-phrase pad is limited by the 300 ms pause anyway.
- Context: the text so far helps slightly on the long clips (en 4.20 vs 5.04 % WER, zh 6.45 vs 8.06 % CER) and costs little time on the device (the decode times of the three phrases of en-1 were 3.05, 3.00 and 2.99 s with 0, 33 and 70 bytes of context). Qwen3-ASR 0.6B can echo the context into its output (seen once on the laptop, a whole previous phrase repeated in front of the next one); `--context N` caps it.
- Not run on the device (the device became unreachable): phrase path without the comparison run (for its own RSS), no context, and a 500 ms pause.

### Recommendation

Use phrase-by-phrase transcription as the recognition path for the chatbot, not as a display-only preview: its final text is available 6-11 s sooner after the end of speech than the whole-utterance run for 12-18 s requests (ja 7.9 vs 19.2 s, zh 9.8 vs 20.9 s, en 9.1 vs 16.7 s), it costs no more total compute, and it is the only one of the two that handles code-switching (CER 4.8 vs 18.1 %). The accuracy cost is small for requests made of separate sentences (en equal, zh +1.1, ja +2.1 points CER) and larger for long continuous sentences cut at short or forced pauses (long English 3.4 vs 1.7 % WER).

Where it falls short:
- Captions are not live: 6-8 s after each phrase, growing by 1-3 s per phrase in a long request, because a phrase costs 1.8 x its duration. It does not keep up with continuous speech on this CPU. For short commands (one or two phrases, under ~5 s) the result is the same as offline: one phrase, transcribed after the speech.
- The wait for a single short command is unchanged (the model is the bottleneck, not the method).
- Words at cuts are occasionally lost; the cut sits in a pause, but weak onsets (`of`, `以`) can fall before the VAD's speech start.

Combining with the incremental conv stem (`patches/0002`): run each phrase through `transcribe_stream_begin/feed/finalize` instead of `transcribe_run`, starting the stream at the phrase's speech onset, so the conv stem (60 % of the encoder) runs while that phrase is spoken and only the transformer and decoder remain at the cut. That would take about 0.8 s off each phrase's 1.8 x (en 2.5 s phrase: 0.5-0.8 s). Two constraints: only one run may be in flight per model, so the conv-stem chunks of phrase n+1 would have to wait for (or be interleaved between) the decode of phrase n, which is exactly when the queue builds; and the context prompt is fixed at `transcribe_stream_begin`, before the previous phrase's text may be ready. The decoder is the larger remaining cost (about 70 % of each phrase); a cached prompt/context prefix and a lower-bit output head (Next 3) help the phrase path more than the offline one, since it pays the prompt once per phrase.

## Reusing the decoder prompt between phrases

`patches/0003-qwen3_asr-prompt-prefix-cache.patch` (on top of 0001 and 0002) keeps the decoder's K/V for the part of the prompt that does not change between phrases and prefills it before the phrase ends.

### What each phrase's decoder does

The prompt is `<|im_start|>system\n` + context + `<|im_end|>\n<|im_start|>user\n<|audio_start|>` + audio + `<|audio_end|><|im_end|>\n<|im_start|>assistant\n`, then the model writes `language X<asr_text>` and the text. So the context sits before the audio, and everything before `<|audio_start|>` is known as soon as the previous phrase's text is: the 9 tokens of the frame around the system message, and the context, which grows by appending a phrase at a time. Only the audio rows and the 6 tokens after them are new for each phrase. No reordering is needed.

Device, recogniser path (`phrase/sla-file`, below), 6 threads, median per phrase of the 45 command clips (single phrases, empty context), 0001+0002:

| Set | Prompt | of which frame / context / audio / after the audio | Prefill | per row | Steps (header + text) | per step | Decoder | Encoder after the cut |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| en | 45 | 9 / 0 / 30 / 6 | 1961 ms | 44 ms | 12 (3 + 9) | 102 ms | 3094 ms | 823 ms |
| ja | 61 | 9 / 0 / 46 / 6 | 2646 ms | 44 ms | 17 (3 + 14) | 106 ms | 4559 ms | 1189 ms |
| zh | 63 | 9 / 0 / 48 / 6 | 2727 ms | 43 ms | 16 (3 + 13) | 106 ms | 4418 ms | 1141 ms |

The prefill is compute-bound at about 44 ms per row on 6 threads; the audio is 13 rows per second of speech. Later phrases of an utterance carry the text so far as context: 10-30 more rows each on the phrase set (0.4-1.3 s of prefill).

### The change

- Session state: the prompt tokens whose K/V are in the cache rows `[0, n)` (the frame and context up to `<|audio_start|>` of the last prompt). A run keeps the rows of the longest common prefix with its own prompt, prefills the rest with a chunked prefill graph (`build_prefill_chunk_graph`: positions from `n`, KV width the whole prompt, the usual causal mask over the cached rows), and records its own prefix afterwards. Rows past the prefix need no clearing (they are masked and rewritten), which also drops the 117 MB KV clear the uncached path does per run.
- `transcribe_stream_begin` prefills the prefix of the run it will finish (frame and context; nothing about the audio is needed), so with the recogniser's streaming the whole prefix is computed while the phrase is spoken, and after the cut only the audio rows and the 6 tokens after them remain. `transcribe_run` alone gets whatever prefix the last run left.
- Exactness. ggml's CPU flash attention takes a tiled path when a graph has 64 or more query rows and a row-by-row one below that, and they round differently; within each path a row's result depends only on that row, the K/V and the mask (checked in `ggml-cpu/ops.cpp`), and the matrix products on the A53 (no repacked weights) are per row. So the result of a prefill split across graphs equals the single-graph one if every row takes the path the single graph over the whole prompt would: each cached row records its path and is reused only by a prompt that would take the same one (prompt of 64+ rows or not); a chunk under 64 rows of a tiled prompt pads its query rows with zero rows to 64 for the attention only, and a chunk of 64+ rows of a row-by-row prompt runs its attention in blocks of 32 (`causal_lm::block_step_n`, new `fa_q_rows` argument). `stream_begin` cannot know the audio length, so it computes the prefix for a short prompt, and `stream_feed` recomputes it on the tiled path once the audio so far makes the prompt 64 rows or longer (still during the speech). A prompt with nothing cached runs the unchanged single-graph prefill.
- `TRANSCRIBE_QWEN3_NO_PREFIX_CACHE=1` switches it all off (the 0001+0002 path, for A/B runs). `TRANSCRIBE_PERF_DEBUG` logs one line per run: prompt rows, reused, prefilled, prefill time, and the max logit after the prompt in hex (`l0=`) for bitwise comparisons.

Two options, both off by default:
- Header draft (`TRANSCRIBE_QWEN3_HEADER_DRAFT=1`): the `language X<asr_text>` ids of the last auto-detected run are appended to the prompt; the prefill's logits at those rows show how many the model predicts itself (greedy), and those are taken as generated (a public speculative-decoding technique with the previous phrase as the draft). Language detection is kept: a wrong draft is just rejected. It is not bit-exact, because the verified rows are computed by the prefill graph, not the step graph, and round differently.
- Forced header (`TRANSCRIBE_QWEN3_FORCE_LAST_HEADER=1`, experiment): for a run with context (a later phrase of an utterance), force the last detected header without checking it.

### Results on the device

`scripts/device-sla.sh TAG cmd --modes off,prefix,draft` runs `phrase/sla-file`: straylight-listen's recogniser (straylight-voice `listen/asr/straylight_asr.cpp`, compiled from that checkout) over WAV files fed in real time, each file once per mode in the same process (rotating the order), as a transient unit next to the running services (installed read-only models, `MemoryMax`, the service's priorities). Caption lag = VAD end of the phrase's speech to its text; end of speech to text = the same for the last phrase. 6 threads, 2026-10-31 22:19-22:42.

| Set | Mode | Prefill | Decoder | Caption lag | End of speech to text | Accuracy |
| --- | --- | --- | --- | --- | --- | --- |
| en (15) | 0001+0002 | 1961 ms | 3094 ms | 4.33 s | 4.33 s | WER 2.08 % |
| en | prefix cache | **1598 ms** | 2735 ms | **4.07 s** | **4.07 s** | WER 2.08 % |
| en | + header draft | 1793 ms | 2613 ms | 3.84 s | 3.84 s | WER 2.08 % |
| ja (15, 18 phrases) | 0001+0002 | 2646 ms | 4559 ms | 6.39 s | 6.68 s | CER 10.39 % |
| ja | prefix cache | **2315 ms** | 4209 ms | **5.99 s** | **6.12 s** | CER 9.83 % * |
| ja | + header draft | 2486 ms | 4089 ms | 5.86 s | 5.96 s | CER 9.83 % * |
| zh (15) | 0001+0002 | 2727 ms | 4418 ms | 6.18 s | 6.18 s | CER 2.99 % |
| zh | prefix cache | **2371 ms** | 3968 ms | **5.77 s** | **5.77 s** | CER 2.99 % |
| zh | + header draft | 2568 ms | 3835 ms | 5.64 s | 5.64 s | CER 2.99 % |

- With empty context (single commands) the cache saves the 9 frame rows: 0.33-0.36 s of prefill and 0.26-0.41 s of caption lag. The prefix was prefilled at stream begin in 0.41 s (9 rows), during the speech.
- English: every phrase's first-token logit is bit-identical with and without the cache (15 of 15), as are the texts.
- \* These runs used an earlier version of the patch that ran the attention of every cached-path row row by row, which differs from the uncached tiled path for prompts of 64+ rows: 3 of the 18 Japanese phrases changed by one word (CER 10.39 to 9.83 %, noise), Mandarin none. The final patch reproduces the uncached path row for row (above); its bitwise check on the device for 64+ row prompts (`scripts/device-prefix-check.sh`, `scripts/prefix-check.py`) and the phrase-set runs could not be done: at 23:00 straylight-listen.service was reinstalled with the TTS loaded (RSS 840-920 MiB), and a second recogniser no longer fits. Under an 800 MB cap the benchmark re-reads its model pages from eMMC (22-28 s caption lag, invalid), and with a 1.1 GB cap the whole system started reclaiming; both were stopped (the service's major faults did not change, no OOM events). They need a window with the service stopped.
- The header draft saves 3 decoder steps (310 ms) for 3 more prefill rows (135-195 ms) when the language repeats: 0.13-0.23 s less lag. Accepted 43 of 45 drafted tokens (en), 52 of 54 (ja), 43 of 45 (zh); the first utterance of a run drafts from the warm-up.

### Phrase set (laptop, accuracy)

`phrase/sla-file --modes off,prefix,draft,force` over the 33 phrase-set utterances on the laptop (native build, real-time feeding, 6 threads; timings on the busy laptop are not meaningful). Corpus WER/CER of the joined text:

| Set | 0001+0002 | prefix cache | + header draft | forced header (experiment) |
| --- | --- | --- | --- | --- |
| en (4) | WER 2.08 % | WER 2.08 % | WER 2.08 % | WER 2.08 % |
| ja (7) | CER 8.61 % | CER 8.61 % | CER 8.01 % | CER 8.01 % |
| zh (5) | CER 3.36 % | CER 3.36 % | CER 3.36 % | CER 3.36 % |
| mixed (8) | CER 5.49 % | CER 5.49 % | CER 5.73 % | **CER 40.33 %** |
| long en (3) | WER 4.20 % | WER 4.20 % | WER 4.20 % | WER 4.20 % |
| long ja (3) | CER 20.81 % | CER 20.81 % | CER 20.81 % | CER 20.81 % |
| long zh (3) | CER 6.45 % | CER 6.45 % | CER 6.45 % | CER 6.45 % |

- Prefix cache: all 33 texts identical to the uncached path. 88 of the 92 phrases were streamed and found their whole prompt prefix (frame + context) cached at the cut; the later phrases of an utterance carried 6-47 context rows (median 18) besides the 9 frame rows. On the device that is 0.4 s (frame) + about 0.8 s (median context) of prefill moved into the speech for each streamed later phrase, 2 s for the longest; a phrase queued behind the previous one (the worker still busy) gets only the rows its prompt shares with the last run, typically the frame. Not measured on the device (above). (On the laptop the x86 kernels, unlike the A53's, are not row-independent, so the first-token logits are bit-identical for only part of the phrases there; the texts still agree.)
- Header draft: 4 of 33 texts change by a word (ja-6 `ニカヤ野菜` to the correct `肉や野菜`; ja-5, mx-5, lx-ja-2 one word each), net CER unchanged to slightly better outside the mixed set. Drafts are rejected at a language switch (mixed: 25 of 57 tokens accepted), which costs the drafted rows.
- Forcing the previous phrase's language is not safe: at a language switch the model translates the speech into the forced language (`軍刀や湖水では…` → `Guntou and Mizumiyō are not necessary in the sea.`), mixed-set CER 5.5 → 40 %. Auto-detection stays; the forced header is only an experiment switch.

### Decision and what is deployed

- The prompt-prefix cache is a clear win: identical results, 0.36 s less prefill for every phrase (the frame), plus the context rows for later phrases, with no extra memory. It is on by default in 0003; straylight-voice carries the patch in `listen/asr/patches/` (no recogniser code change: it already begins each stream while the phrase is spoken). Not installed on the device: the installed straylight-listen is the one the TTS work builds and installs, and the next `listen/asr/build.sh` picks up 0003.
- The header draft (another 0.13-0.23 s per phrase when the language repeats) is left opt-in, because it is not bit-exact; enabling it would be `TRANSCRIBE_QWEN3_HEADER_DRAFT=1` in the unit's environment.
- Left to do with the service stopped (a second recogniser no longer fits next to the TTS): `scripts/device-prefix-check.sh` (bitwise check of 64+ row prompts on the A53) and `scripts/device-sla.sh TAG phrase --modes off,prefix,draft` (caption lag on the phrase set).

### Scripts

| Script | What |
| --- | --- |
| `phrase/sla-file.cpp` (built by `phrase/build.sh`) | straylight-listen's recogniser over WAV files, per-phrase times and the decoder prefill log, `--modes off,prefix,draft,force` |
| `scripts/device-sla.sh TAG cmd\|phrase [options]` | that on the tablet next to the running services (locked, memory-capped, installed models) |
| `scripts/sla-summary.py RESULTS.jsonl...` | prefill, decoder, caption lag, end of speech to text, accuracy per set and mode; text and logit comparisons |
| `scripts/device-prefix-check.sh [N] [LANGS]`, `scripts/prefix-check.py DIR` | bitwise check of the cache against the uncached path with transcribe-cli (batch, streaming, with and without context) |

## The GPU

Not useful for this model: the Adreno 506 reaches about 14 GFLOP/s FP32 in OpenGL ES 3.1 compute shaders, half the CPU's Q8_0 rate, with slow readback and shared memory bandwidth (`../gpu-compute/NOTES.md`).

## Next

0. Prefill on the GPU, once the fragment-shader kernels from `streams/kokoro-gpu/` reach about 30 GFLOP/s. Prefill is compute-bound GEMM (about 50 GFLOP per phrase, 1.6-2.4 s at the CPU's ~27 GFLOP/s); GPU and CPU in parallel could roughly halve it. Decode is bandwidth-bound and gains nothing from the GPU, which shares the LPDDR3 channel. There is no memory for a second copy of the weights, so the GPU must hold the original Q4_K/Q8_0 blocks in integer textures (~350 MB) and replace the CPU's mapped copy, with decode moving to the GPU too. ASR and TTS never use the GPU at the same time.
1. Speculative decoding (`--spec-k-drafts`) for the decoder steps (Qwen3-ASR does not report `supports_spec_decode` at the pinned commit).
2. Shorter prompt: 18 of the 80 prefill tokens are prompt. (The 9 frame tokens and the context are now cached, `patches/0003`; what is left per phrase is the audio rows and the 6 tokens after them.)
3. The output head is 122 MiB of Q6_K read on every decoder step; a lower-bit head would cut step time.
4. Choose and benchmark a speech synthesiser for English, Japanese and Mandarin; check recognition and synthesis fit in RAM together.
