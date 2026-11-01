# asr-fast: sub-second speech recognition (in progress)

Goal: captions that trail speech by under about 1 s, and final text under about 1 s after the user stops, in English, Japanese and Mandarin. Qwen3-ASR-0.6B (`streams/asr/`) needs 4.1 / 6.1 / 5.8 s (en / ja / zh) after end of speech even with patches 0001-0003, because its decoder is autoregressive (about 100 ms per token) and its prefill is compute-bound. This stream looks at non-autoregressive (CTC) and streaming-transducer models instead, through sherpa-onnx on the device.

**Status (2026-11-01): stopped part way.** The accuracy screen on the laptop is done; device speed, the hybrid runs and integration are not.

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

## Not done

- Device speed (RTF, latency after end of speech, caption lag, RSS, wake-detector timing) for the candidates: `scripts/device-bench.sh`, `scripts/device-quick.sh`, `bench/` (`sla-bench`).
- The hybrid runs (`work/hyb3-run.log` is the last one started).
- Hotword / contextual biasing for "Straylight" and "ai&" (term lines in `work/terms/lines.tsv`).
- Integration: the straylight-voice branch `asr-fast` (worktree `/home/jethac/Projects/straylight-voice-asr`) has a sherpa-onnx recognizer backend (`listen/asr/straylight_sherpa.cpp`, `--asr-backend`) in progress, committed there as work in progress and not on main or the device.
- Licences: check SenseVoice's model licence (FunASR model licence, attribution terms) before shipping.

## Layout

- `scripts/screen.py`, `scripts/screen-score.py`: laptop accuracy screen and scoring.
- `scripts/device-*.sh`: device runs (take the device lock; keep the listener up).
- `work/` (not tracked): models, screen outputs, logs.
