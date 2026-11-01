# asr-fast: sub-second speech recognition (in progress)

Goal: captions that trail speech by under about 1 s, and final text under about 1 s after the user stops, in English, Japanese and Mandarin. Qwen3-ASR-0.6B (`streams/asr/`) needs 4.1 / 6.1 / 5.8 s (en / ja / zh) after end of speech even with patches 0001-0003, because its decoder is autoregressive (about 100 ms per token) and its prefill is compute-bound. This stream looks at non-autoregressive (CTC) and streaming-transducer models instead, through sherpa-onnx on the device.

**Status (2026-11-01): stopped part way.** The accuracy screen and one device run of the hybrid are done (below: about 1.1-1.75 s from end of speech to text, against 4-6 s for Qwen3-ASR); the other hybrid variant, long-segment handling and integration are not.

## Accuracy screen (laptop, same clips as `streams/asr/`)

Error rate in % (WER for en, CER for ja and zh); `en/ja/zh` are the 15-clip command sets, `p-*` the phrase set (`p-mx` mixed English and Japanese), `lx-*` the longer clips. From `scripts/screen-score.py work/screen/*` (run with `uv run`).

| model | en | ja | zh | p-en | p-ja | p-zh | p-mx | lx-en | lx-ja | lx-zh |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **SenseVoice-Small 2024** | 7.29 | **4.21** | **4.10** | 4.17 | 5.93 | 2.99 | **9.55** | 3.36 | 10.74 | 7.26 |
| SenseVoice-Small 2025 | 9.38 | 82.87 | 6.34 | 11.46 | 83.98 | 5.22 | 27.45 | 15.97 | 79.19 | 8.06 |
| multilingual 8-language (2025) | 4.17 | 8.71 | 32.46 | 8.33 | 27.60 | 11.57 | 39.62 | 7.56 | 13.42 | 28.23 |
| xasr-480 (en/zh) | 4.17 | n/a | 4.48 | 4.17 | n/a | 4.10 | 38.42 | 2.52 | n/a | 18.55 |
| Moonshine ja | n/a | 11.80 | n/a | n/a | 8.61 | n/a | 75.42 | n/a | 6.04 | n/a |
| Moonshine zh | n/a | n/a | 8.96 | 17.71 | n/a | 6.34 | 61.58 | 21.85 | n/a | 34.68 |
| Moonshine en | 5.21 | n/a | n/a | 2.08 | n/a | n/a | 66.35 | 4.20 | n/a | n/a |
| kroko-en | 3.12 | n/a | n/a | 3.12 | n/a | n/a | 69.93 | 3.36 | n/a | n/a |
| zipformer en 20M | 56.25 | n/a | n/a | 14.58 | n/a | n/a | 92.84 | 10.08 | n/a | n/a |

"n/a" marks a language the model does not cover (its scores there are over 100 %). For reference, Qwen3-ASR: en 2.08, ja about 6.5-10, zh about 2.6-3, mixed 4.8 (phrase by phrase).

Reading: SenseVoice-Small (2024 release) is the only single model that is usable in all three languages and on mixed speech; it beats Qwen3-ASR on Japanese and is within about 1.5x on Mandarin, but English is about 3.5x worse on the short commands (7.3 vs 2.1 WER). The 2025 SenseVoice release regresses Japanese badly. A hybrid (SenseVoice for language ID, captions and ja/zh; an English-only model such as kroko-en or Moonshine en for English segments) was being measured when the stream stopped.

## Device: hybrid SenseVoice + streaming Zipformer (2026-11-01)

`hyb-xasr`: SenseVoice-Small 2024 int8 (`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`) for the final text of every segment, plus the streaming zipformer transducer `sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05` (3 threads) for live en/zh captions; 6 threads; clips fed at real time through `bench/sla-bench` next to the running listener (`scripts/device-bench.sh`, results `work/device/out-hyb-xasr.jsonl`, summary `uv run scripts/bench-summary.py`). CPU at 1804.8 MHz, 40 °C.

| set | end of speech → text | final | caption lag | accuracy | Qwen3-ASR (phrase, 0003) |
| --- | --- | --- | --- | --- | --- |
| cmd-en | 1.19 s | 1.19 s | 0.65 s | WER 4.17 % | 4.07 s, WER 2.08 % |
| cmd-ja | 1.75 s | 1.61 s | 0.79 s | CER 5.34 % | 6.12 s, CER ~10 % |
| cmd-zh | 1.09 s | 1.09 s | 0.35 s | CER 4.10 % | 5.77 s, CER ~3 % |
| mixed en/ja | 1.34 s | 1.31 s | 0.57 s | CER 4.30 % | CER 4.8 % |
| long en | 8.08 s | 6.78 s | 0.35 s | WER 6.72 % | |
| long ja / zh | 2.15 / 2.09 s | 2.73 / 1.42 s | 0.90 / 0.34 s | CER 13.4 / 12.9 % | |

- Wake-detector deadline: worst block 7 ms late, none missed.
- Memory: about 570 MiB anonymous (not reclaimable), 23 MiB file-backed; model open takes 47 s. Qwen3-ASR's 550 MB is file-backed instead, so swapping backends changes how memory behaves under pressure: measure the full listener with zram on.
- Long English falls behind: the final pass needs 13 s of CPU after the audio ends (flush 2.7 s per segment), so long segments must be cut shorter or the final pass run on segments as they close.
- Japanese has no streaming model in this hybrid (live captions come from SenseVoice per segment, hence ~0.8 s).

## Not done

- Device speed (RTF, latency after end of speech, caption lag, RSS, wake-detector timing) for the candidates: `scripts/device-bench.sh`, `scripts/device-quick.sh`, `bench/` (`sla-bench`).
- The `hyb3` variant (kroko-en streaming for English instead of x-asr), cancelled before it ran.
- Hotword / contextual biasing for "Straylight" and "ai&" (term lines in `work/terms/lines.tsv`).
- Integration: the straylight-voice branch `asr-fast` (worktree `/home/jethac/Projects/straylight-voice-asr`) has a sherpa-onnx recognizer backend (`listen/asr/straylight_sherpa.cpp`, `--asr-backend`) in progress, committed there as work in progress and not on main or the device.
- Licences: check SenseVoice's model licence (FunASR model licence, attribution terms) before shipping.

## Layout

- `scripts/screen.py`, `scripts/screen-score.py`: laptop accuracy screen and scoring.
- `scripts/device-*.sh`: device runs (take the device lock; keep the listener up).
- `work/` (not tracked): models, screen outputs, logs.
