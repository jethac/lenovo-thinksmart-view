# wakeword stream

"Hey Straylight": an always-on wake-word detector on the ThinkSmart View, trained from synthetic speech, and the listener daemon that puts the Straylight screen into Listening.

## Status (2026-10-31)

Running on the tablet. `straylight-listen.service` (straylight-voice repository, `listen/`) captures the microphones, detects the phrase and drives the screen. Accuracy on held-out synthetic speech at threshold 0.5: 95 % of clean utterances and 72-86 % of noisy, reverberant ones (lowest for Mandarin-accented), with no false accepts in 16 h of held-out speech and music. Through the tablet's own speaker and microphones: 27 of 30 detected, no near miss fired. CPU about 4 % of one A53 core at full clock (12.8 % of CPU time at the 652 MHz that schedutil picks for it), 10-14 MiB resident.

## What is where

| What | Path |
| --- | --- |
| Daemon, front end, packaging, README (audio decision, licences) | `~/Projects/straylight-voice/listen/` (pushed to `git@github.com:jethac/straylight-voice.git`) |
| Downloads, venv, training data | `downloads/` (git-ignored; 14 GB with the venv) |
| Clips, features, models, logs | `work/` (git-ignored, 8.4 GB); final model `work/models/v5-final/` |
| Scripts | `scripts/`, below |

## Engine

- **openWakeWord** ([dscripka/openWakeWord](https://github.com/dscripka/openWakeWord) at `368c0371`, Apache-2.0): a frozen front end (512-point STFT log-mel, 32 bins, then Google's speech_embedding network, 96 values per 80 ms) and a small classifier per phrase over 16 embeddings (1.28 s of new audio, about 2 s with the network's receptive field). Chosen over microWakeWord for training from synthetic speech against a large precomputed negative set, with a known recipe, and because its front end can be computed without any ML runtime.
- **Front end in Rust, not ONNX Runtime.** ONNX Runtime on the laptop needed 6.2 ms of one i7 core per embedding window (8 % of a core at 12.5 windows/s); on the A53 that would be several times more. The embedding network is valid convolutions and poolings whose time strides multiply to 8 mel frames, the same as the step between windows. So each layer's rows are kept and only new rows computed: 5.6 MMAC per 80 ms instead of 42 MMAC (`listen/src/frontend.rs`). The mel spectrogram is an FFT: the ONNX STFT weights are exactly a window times cos/sin. Embeddings equal openWakeWord's streaming `AudioFeatures` to 7e-5, on the laptop and the tablet.
- **Getting it under budget on the A53** (60 s of LibriSpeech, file mode, CPU up to 1.8 GHz):

  | Kernel | CPU per 60 s audio |
  | --- | --- |
  | im2col + `matrixmultiply` sgemm | 6.7 s (11.2 %) |
  | channel-last axpy | 7.5 s |
  | 4x8 register blocks, `mul_add` (not vectorised) | 7.9 s |
  | NEON `vfmaq_n_f32` | 6.5 s |
  | NEON, weights re-laid out per block of 8 output channels | **2.7 s (4.5 %)** |
  | NEON lane-wise (4 input channels per load) | 2.66 s (no gain) |

  The narrow late layers (62-110 KB of weights) overflowed the 32 KB L1 and were read with a stride of `cout`. The in-order A53 cannot hide that. Re-laying the weights out contiguously per 8-channel block cut the time 2.4x. The good layers now run at about 1.2 MAC per cycle against a peak near 2 for the A53's 64-bit NEON pipe.

## Licences

| What | Licence | Used for |
| --- | --- | --- |
| openWakeWord code, `melspectrogram.onnx`, `embedding_model.onnx` (v0.5.1 assets) | Apache-2.0 (embedding network: Google speech_embedding, Apache-2.0) | front end, in the daemon |
| openWakeWord ACAV100M features (`davidscripka/openwakeword_features`) | **CC BY-NC-SA 4.0** | general negatives (6 slices, 1.5 M windows, ~533 h) |
| openWakeWord false-positive validation features (DiPCo, Santa Barbara corpus, MUSDB) | CC BY-NC-SA 4.0 | checkpoint selection only |
| piper-sample-generator (`2971426a`) and its LibriTTS-R generator `en_US-libritts_r-medium.pt` | MIT; voices trained on LibriTTS-R, CC BY 4.0 | positives, near misses |
| Magpie TTS Multilingual 357M + NanoCodec (see `../tts/NOTES.md`) | NVIDIA Open Model License; no rights claimed in generated audio | positives, near misses |
| MUSAN (`corypaik/musan` parquet copy) noise, music, speech | CC BY 4.0 | background augmentation, music false-accept test, speech negatives for the no-ACAV variant |
| Room responses | simulated with pyroomacoustics (MIT) | reverb |
| LibriSpeech test-clean, FLEURS ja/zh test (from `../asr/downloads/`) | CC BY 4.0 | false-accept tests only |

The installed model was trained with ACAV100M (non-commercial), so it may carry that restriction. The no-ACAV variant (`work/models/v6-permissive/`, `out/listen/hey-straylight-no-acav.slt` in straylight-voice) uses only permissively licensed data. It is as quiet but misses more (below).

## Training data

- **Positives.**
  - Piper LibriTTS-R: 30,000 clips. Each mixes two random speakers out of 0-799 by SLERP, with length scale 0.75-1.3 and varied noise scales, over 8 spellings of the phrase (`scripts/phrases.py`).
  - Magpie: speakers 0-3 (Aria, Jason, John, Leo), 26 seeds × 12 texts. English text in en mode; katakana or hiragana, or English text, in ja mode (Japanese-accented); hanzi transliteration or English text in zh mode (Mandarin-accented); temperature 0.55-0.85. 1,248 clips; 1,099 kept after dropping clips over 1.9 s once trimmed (slow readings that do not fit the window). Laptop ASR (Qwen3-ASR) heard "Hey, stray light." / "ヘイストレーライト" / "黑斯特雷莱特" for most; a few Japanese-mode takes were garbled.
- **Near misses.** 46 English phrases for Piper (20,000 clips, two windows each), 29 for Magpie in three modes (348 clips): "hey" alone, "Straylight" alone, "stray light" / "a stray light", "hey Siri", "hey Google", "Alexa", "hey starlight", "hey skylight", "hey daylight", "satellite", and so on. "Stray light" sounds the same as "Straylight", so only its forms without "hey" are negatives. Plus "partial" negatives: the first 45-70 % of positive clips ("hey stray-"), so the phrase must finish before it fires.
- **General negatives.** ACAV100M features (1.5 M windows). 20,000 MUSAN noise and music windows. For the no-ACAV variant: 60,000 MUSAN speech windows instead of ACAV100M.
- **Augmentation** (`scripts/make-features.py`): trim silence; parametric EQ (p 0.3); low-pass 3-7.5 kHz (p 0.2); reverb from 400 simulated rooms (p 0.6; RT60 0.15-0.9 s, 0.5-4 m); speech level -50 to -12 dBFS; MUSAN noise or music at -3 to 25 dB SNR (p 0.8); coloured noise (p 0.3); a -85 to -65 dBFS floor. Test sets use 100 separate rooms and a held-out 10 % of the noise and music files.
- **Features are the daemon's own.** `straylight-listen --windows 33280 --dump-embeddings` gives each 2.08 s window's last 16 embeddings from a cold start, exactly what the detector sees as the phrase ends (0-250 ms after it).

## Training

`scripts/train.py`: openWakeWord's "dnn" head (Linear 1536→64, LayerNorm, ReLU, one more 64-wide block, output), on the laptop's GTX 1650 Ti. Batches: 192 Piper + 64 Magpie positives, 192 near misses, 64 background, 1536 general negatives. BCE with the negatives' weight ramped to `--max-neg-weight`. Validation every 500 steps on 5 % of the positives and openWakeWord's 10.7 h false-positive validation set. Kept: the best recall under 0.5 false accepts per hour on it.

| Run | Data | Settings | Kept |
| --- | --- | --- | --- |
| v1 | Piper only | weight 1500, 20k steps | step 9500: window recall 0.51 |
| v2 | Piper only | weight 300 | step 9000: 0.59; overfits after (fp-val 27/h at 20k) |
| v3 | Piper only | weight 300, dropout 0.3, AdamW 0.01 | step 18500: 0.60, stable |
| v4 | + Magpie positives | as v3, 30k steps | step 25500: 0.62 |
| **v5** | + Magpie near misses | as v4 | **step 29000: 0.62 (installed)** |
| v6 | as v5, no ACAV100M, MUSAN speech instead | as v4 | step 9000: 0.55 |

## Results

`scripts/eval.py MODELDIR` (`work/models/*/eval-p1.json`). Recall is per utterance: fires in any of the 4 consecutive 80 ms windows after the phrase ends. Held out: Piper speakers 800-903, Magpie's Sofia (speaker 4) and unseen seeds. False accepts: straylight-listen's embeddings of long audio, scored every 80 ms with the daemon's rule (fire, then 2 s refractory).

v5 (installed), patience 1:

| | 0.3 | 0.4 | **0.5** | 0.6 | 0.7 | 0.8 |
| --- | --- | --- | --- | --- | --- | --- |
| Piper unseen voices, clean (2000) | 97.3 | 96.6 | **95.4** | 94.3 | 92.9 | 90.7 |
| Piper unseen voices, augmented (2000) | 85.0 | 83.4 | **81.6** | 79.5 | 77.5 | 74.5 |
| Magpie Sofia + unseen seeds, clean, all modes (444) | 95.9 | 95.0 | **94.8** | 93.5 | 92.1 | 91.0 |
| Magpie English, augmented (148) | 87.2 | 85.8 | **85.8** | 83.8 | 81.1 | 77.7 |
| Magpie Japanese-accented, augmented (148) | 85.1 | 83.8 | **82.4** | 80.4 | 79.1 | 73.6 |
| Magpie Mandarin-accented, augmented (148) | 74.3 | 73.6 | **72.3** | 67.6 | 63.5 | 56.1 |
| Near misses fired, held out (4232 windows), % | 0.1 | 0.1 | **0** | 0 | 0 | 0 |
| False accepts / h, LibriSpeech test-clean (5.6 h) | 0 | 0 | **0** | 0 | 0 | 0 |
| False accepts / h, FLEURS ja test (2.4 h) | 0 | 0 | **0** | 0 | 0 | 0 |
| False accepts / h, FLEURS zh test (3.2 h) | 0.32 | 0 | **0** | 0 | 0 | 0 |
| False accepts / h, MUSAN music held out (4.8 h) | 0 | 0 | **0** | 0 | 0 | 0 |
| False accepts / h, openWakeWord fp validation (10.7 h, used for selection) | 0.37 | 0.37 | **0.28** | 0.09 | 0 | 0 |

So at 0.5: 0 false accepts in 16.0 h of held-out speech (English, Japanese, Mandarin) and music, 3 in the 10.7 h validation set. The confidence on that is limited: zero in 16 h bounds the rate below about 0.2 per hour (95 %). An evening of real conversation in the room is the real test.

v6 (no ACAV100M) at 0.5: Piper clean 92.5 %, augmented 77.0 %; Magpie clean 92.3 %, English 81.1 %, Japanese-accented 63.5 %, Mandarin-accented 60.1 %; near misses 0; false accepts 0 in the 16 h, 0.37/h on validation.

The Mandarin-mode Magpie positives are the weakest: their hanzi readings (嘿，斯特雷莱特) are slow, often over 2 s, longer than the window.

## On the tablet

- **File mode** (`--input`, detector only), the 160 s test file (30 held-out positives, 12 held-out near misses, -20 dBFS): 29/30 detected (en 6/6, ja 6/6, zh 5/6, Piper 12/12); 0/12 near misses. 7.4 s of CPU for 160 s.
- **Live, acoustic loopback.** The same file at 48 kHz played through the tablet's speaker (amp 187 = -10 dB, restored to 145 after) and captured by the service's own path (`hw:0,1`, mic mix, +24 dB). 27/30 detected (en 6/6, ja 6/6, zh 3/6, Piper 12/12); 0/12 near misses; no wake away from a clip end (`scripts/score-loopback.py`, log in `work/device/loopback-v5-live.log`).
- **Screen.** `--input --realtime` with the screen running: Idle → `listening` at the wake → back to `idle` after 5 s without speech, polled with `straylight-voicectl get`. A tap injected with straylight-voice's `tools/tap.c` during Listening gave `cancel`; the listener logged it, dropped the utterance, and the screen was Idle.
- **CPU and memory.** File mode: 2.7 s CPU per 60 s audio (4.4 % of a core; mel 0.2 s, network 2.5 s). The service, idle in a quiet room, over 60 s: 12.8 % of one core by CPU time, with policy0 at 652 MHz for 45 s and 1.8 GHz for 12 s. In cycles that is the same as file mode (4.4 % at 1.8 GHz = 12.1 % at 652 MHz). The `--stats` log during the loopback said 11.8-12.3 %. RSS 9.6 MiB during the test, 14 MiB just after a restart; cgroup 12 MiB. Device MemAvailable 1620 MiB with screen and listener running.
- **Microphones.** Both DMICs work through `CIC1/2 MUX = DMIC`, `DEC1 MUX = DMIC1`, `DEC2 MUX = DMIC2`, `MultiMedia2 Mixer TERT_MI2S_TX = 1`, `hw:0,1`, 48 kHz S16_LE stereo. Quiet room: -81.5 / -81.9 dBFS per channel at TX 84 (0 dB), noise correlation 0.2. Speech from the speaker at amp -10 dB, normalised to -20 dBFS, reached the mics at -68 dBFS typical, -62 peak. So the daemon sets TX1/TX2 to 108 (+24 dB); its noise floor estimate then reads -63 dBFS.

## Audio-capture decision

ALSA directly, PipeWire left off. Written up in the straylight-voice README ("The listener and audio") and `listen/README.md` ("Audio"). In short: nobody logs in on the appliance, so the user PipeWire never runs, and a system PipeWire is unsupported upstream. Capture `hw:0,1` and playback `hw:0,0` are separate PCMs at the QDSP6's fixed 48 kHz / 2 ch / S16_LE, each with one user. Speech output should open `hw:0,0` the same way (route `QUAT_MI2S_RX Audio Mixer MultiMedia1`, volume `Speaker Amp Digital Playback Volume`), preferably in the same process for echo cancellation later.

For the image (`rootfs/scripts/`, not changed here): install the listener's files like the screen's (`/usr/local/bin/straylight-listen`, `/usr/local/share/straylight-listen/{frontend,hey-straylight}.slt`, the unit and `/etc/straylight-listen.conf`) and `systemctl enable straylight-listen.service`. alsa-lib and alsa-utils are already in the image. A mic UCM device in `cd-18781y/HiFi.conf` is not needed by the listener (it sets the controls itself).

## Scripts

| Script | What |
| --- | --- |
| `fetch.sh [code\|models\|negatives\|musan\|all]` | openWakeWord, piper-sample-generator, front-end ONNX files, generator model, ACAV100M slices by HTTP range, validation features, MUSAN shards |
| `phrases.py` | wake-phrase spellings and near misses, both generators |
| `gen-piper.py OUT {pos\|neg} N SEED {train\|test}` | Piper LibriTTS-R clips (GPU), train speakers 0-799, test 800-903 |
| `gen-magpie.py OUT {pos\|neg} {train\|test} [WORKERS]` | Magpie clips via the laptop NeMo-Speech.cpp build in `../tts` |
| `make-rirs.py OUT N SEED` | simulated rooms |
| `musan-extract.py OUT SHARD...` | MUSAN parquet to 16 kHz WAVs |
| `make-features.py OUT MODE COPIES SEED SPLIT DIR...` | augmentation and features (modes pos, neg, partial, bg, clean, utt, utt-clean; `BG_SET` picks background dirs) through straylight-listen |
| `make-long.py PREFIX @LIST` | long WAVs for false-accept tests |
| `train.py OUT [...]` | training; `--no-acav --extra-neg bg-speech-train` for the permissive variant |
| `export.py CKPT OUT` | a checkpoint to `.slt` and `.onnx` |
| `eval.py MODEL [--patience N]` | recall, near misses, false accepts per hour |
| `score-loopback.py LOG MARKS` | the live loopback test's wakes against its clips |

Reproduce: `fetch.sh all`; venv as in `downloads/venv` (uv, Python 3.11, torch 2.8.0+cu126, onnxruntime, piper-tts 1.3.0, audiomentations, pyroomacoustics, soundfile, pyarrow, plus openWakeWord and piper-sample-generator from `downloads/`, without dependencies). Then the generators, `make-rirs.py`, `musan-extract.py`, `make-features.py` for each set (`work/feat-*.log` show the invocations), `train.py work/models/v5-final --steps 30000 --max-neg-weight 300 --dropout 0.3 --weight-decay 0.01`, `eval.py`. Training data generation took about 3 h on the laptop, most of it Magpie on the CPU; training is 10 min.

## Left on the device

- straylight-voice `listen/packaging/install.sh` files: `/usr/local/bin/straylight-listen`, `/usr/local/share/straylight-listen/`, `/etc/systemd/system/straylight-listen.service` (enabled), and `/etc/straylight-listen.conf`. The conf has `--stats 600 --record /var/lib/straylight-listen`, so the user's tries are kept (newest 20 WAVs after each wake); drop `--record` once that is no longer wanted.
- Mixer state set by the listener: the mic route above and TX1/TX2 Digital Volume 108. Speaker amp volume back at 145.
- Test files in `/dev/shm/wk` removed.

## Next

1. Recognition: phrase-stream behind the `Recognizer` trait (C API around `transcribe_*`, linked into straylight-listen), with Captions from `poll()`.
2. Real-voice data: the `--record` WAVs and some recordings of the household saying the phrase and near misses, to check recall on real voices and fine-tune if needed. The model has only heard synthetic speech.
3. A longer false-accept run on real room audio (an evening of TV and talk) with `--record` off and the journal's wake lines counted.
4. Speech output on `hw:0,0` in the same process (and AEC for barge-in).
