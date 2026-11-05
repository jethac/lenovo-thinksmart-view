# tts-distil: real-time voices distilled from Kokoro

Goal: continuous speech on the tablet in Japanese (today Kokoro on the CPU, RTF about 3, so replies come in pieces) and a licence-clean Mandarin (today's fast Piper AISHELL-3 voice fails the commercial-use rule), optionally English too so one persona speaks all three. Method: Kokoro-82M (Apache-2.0) renders clean-licence text in the chosen voices (en `af_heart`, ja `jf_alpha*0.7+af_heart*0.3`, zh `zf_xiaoni*0.7+af_heart*0.3`) from the tablet's own phonemiser output; a small Matcha-TTS (MIT) student per language learns from it, with a Vocos vocoder trained on the same Kokoro audio, so the licence chain is clean end to end. Target on the tablet: RTF ≤ 0.5 on 6 threads (the LJSpeech Matcha + Vocos already measures 0.41-0.50, see `streams/tts/NOTES.md`).

**Status (2026-11-04): all three voices trained, measured and installed on the tablet** (straylight-voice main `70d584b`, built `--features asr,tts`; `/etc/straylight-listen.conf`: `--tts-voice en=paradee:en-heart --tts-voice ja=paradee:ja-alpha --tts-voice zh=paradee:zh-xiaoni`; voices in `/usr/local/share/straylight-listen/paradee/`). To make room, the `.onnx` files that sat next to their `.ort` were removed from the tablet (Kokoro uint8, Piper AISHELL-3, Matcha LJSpeech model and Vocos; the listener memory-maps the `.ort` files, so Kokoro and Piper stay usable as fallbacks); root has 274 MB free. Previous binary and conf kept as `*.pre-paradee`. The image build does not stage any TTS files yet (`rootfs/scripts/straylight/extra-files.tsv` still lists Kokoro as commented-out placeholders, and `build-straylight.sh` builds the listener with `--features asr` only): it needs `asr,tts`, the three voice directories and the `.ort` files only. Left to do: a first-piece rule for Mandarin in the listener's text splitter (first audio 1.2-2.9 s).

Narrow Kokoro students (Kokoro-82M's own text side, an iSTFTNet decoder at 1/4 width with two resblock kernels, `x25k2`, trained on Kokoro's renders of our CC0 / public-domain corpus), exported as one ONNX graph each with Kokoro's interface, MatMul-only uint8:

| | en af_heart | ja jf_alpha*0.7+af_heart*0.3 | zh zf_xiaoni*0.7+af_heart*0.3 |
| --- | --- | --- | --- |
| UTMOS (teacher) | 4.40 (4.51) | 4.26 (4.39); installed 4.22 | 3.81 (4.23) |
| SHEET SSL-MOS (teacher), not English-only | 4.517 (4.575) | 4.648 (4.660) | 4.624 (4.646) |
| WER / CER (teacher) | 0.8 % / 5.3 % (1.6 / 4.9) | CER 8.0 % (8.4) | CER 1.4 % (2.9) |
| timbre: LTAS diff, MFCC dist (the tablet's Kokoro uint8) | 0.47 dB, 0.92 (0.82, 14.1) | 0.46 dB, 0.87 (1.52, 11.0) | 0.67 dB, 2.19 (0.83, 14.3) |
| tablet RTF, speech path (Kokoro) | 0.58-0.62, median 0.60 (2.9-3.0) | 0.54-0.57 (2.95-3.15) | 0.54-0.55 (2.9) |
| first audio | 0.93-1.73 s, median 1.40 | 1.08-1.51 s | 1.2-2.9 s (splitter) |
| speech process peak RSS | 260 MiB | 291 MiB | 608 MiB with Kokoro en loaded too |
| snapshot | stage 2 step 28,000 | stage 2 step 30,000 of a second run (`ja-alpha-v2`, not installed yet; installed: first run, step 20,000) | stage 2 step 28,000 |

- Files (PGX `~/straylight-tts/export/narrow-<lang>-x25k2_s2-<step>-u8mm/`: `model.onnx`, `voice.bin`; packed for the tablet as `.ort` + `voice.bin`, 109 MB each, in this stream's `work/voices/{en-heart,ja-alpha,zh-xiaoni}/`, git-ignored). Checkpoints: PGX `~/straylight-tts/paradee/<lang>/checkpoints/narrow_x25k2_s1|_s2/` (every 2,000 steps).
- Integration: straylight-voice branch `tts-distil-en` (worktree `/home/jethac/Projects/straylight-voice-distil-en`), `--tts-voice L=paradee:NAME`.
- English was tried in the live service from tmpfs (2026-11-04 02:35-04:51 JST, the final voice from 04:00) and then put back: the root file system had too little room for a permanent install at the time (118 MB free; 238 MB when reverting, it moves as other streams work), and the deployed binary is a build this branch does not contain, so replacing it is for the integrator.
- Matcha + Vocos (the original plan) is kept only as a fallback; no language needed it.
- RunPod: $19.26 in all ($14.51 first round, $4.75 for the second Japanese run), no pods or volumes left ([RunPod](#runpod-from-2026-11-03)).
- Second round (2026-11-04): [UniDic vs NAIST, the Mandarin gap, v1.1-zh, misaki input](#second-round-2026-11-04-japanese-front-end-mandarin-measures-and-teacher-misaki-input). In short: NAIST stays (a tie through the teacher, and UniDic needs 725 MB); the Japanese student was retrained through the whole stage 2 (UTMOS 4.26, a small gain); the Mandarin UTMOS gap is UTMOS's (on SHEET, a predictor trained with Mandarin data, the zh gap is 0.02, smaller than English's 0.06); v1.1-zh recognises better but is a different voice and needs a new front end, so it is proposed, not run; the students take Python misaki's phonemes with no loss of naturalness.

Install (integrator): build straylight-voice `tts-distil-en` (merged with whatever the tablet runs now), copy a voice directory to `/usr/local/share/straylight-listen/paradee/NAME/` (`model.ort`, `voice.bin`; 109 MB each), and set `--tts-voice en=paradee:en-heart` (and `ja=paradee:ja-alpha`, `zh=paradee:zh-xiaoni`) in `/etc/straylight-listen.conf`. Room: about 110 MB per voice; the documented saving is the `.onnx` files kept next to their `.ort` (Kokoro uint8 177 MB, Matcha LJSpeech 74 + 54 MB). With all three languages on students, Kokoro (and its 177 + 178 MB of model files) is no longer needed at all unless kept as a fallback.

History (2026-11-03): the original Matcha run's "cannot locate TextMelDataModule" was not a path problem (Hydra hid `RuntimeError('espeak not installed')` from `matcha/text/cleaners.py`; `scripts/matcha-setup.sh` fixes it), and checkpoints are now every 2,000 steps for every trainer. On the GB10, CUDA fails to create its context in a container capped at 24 GB; `scripts/pgx-run.sh` takes `MEM`, and 32 GB works. The Strix Halo refused our SSH key all day, so it was not used. The track changed twice by the user's decision: Matcha + Vocos, then Paradee's own student, then the narrow Kokoro student with the teacher's text side.

## The narrow Kokoro student

- **Text side: Kokoro-82M v1.0's own** (PL-BERT 6.29M parameters, its projection 0.39M, the prosody predictor 16.20M, the text encoder 5.61M), frozen, not distilled: durations, F0, energy and the aligned phoneme features are exactly the teacher's, so Japanese pitch accent and Mandarin tones come from the teacher's own predictor. Measured (`scripts/paradee/narrow.py`, PyTorch's FLOP counter): 155 MFLOP per phoneme (BERT, predictor encoder and duration head, text encoder; the LSTMs are not counted by the counter) plus 0.61 GFLOP per second of audio for the F0/energy curves; at 13-15 tokens per second of speech (our renders: en 15.0, ja 13.3, zh 14.5) that is about 3 GFLOP per second of audio.
- **Decoder: Kokoro's iSTFTNet `Decoder` at reduced widths** (`StyledDecoder` in `narrow.py`): AdaIN width W and generator `upsample_initial_channel` U; everything else is the teacher's (upsample rates [10, 6], kernels [20, 12], dilations [1, 3, 5], post n_fft 20, hop 5, style_dim 128). Conditioned on the voice's style row (`pack[n - 1]`, its decoder half), so the shipped voice is the teacher's own pack (`voice.bin`, our blends included).
- **Training** (`scripts/paradee/train_narrow.py`): teacher forcing on the teacher corpus (the teacher's aligned features, F0, energy and audio), Paradee's decoder losses: stage 1 log-mel L1 + multi-resolution STFT (30,000 steps, batch 16 x 64 frames, AdamW 2e-4, cosine), stage 2 MPD + multi-resolution spectrogram discriminators with feature matching (spectral losses x10 then x3, as Paradee's decoder stages). A snapshot every 2,000 steps with held-out WAVs and DTW log-mel distance; the best point of the curve is picked by the evaluation below.
- **Export** (`scripts/paradee/export_narrow.py`): one ONNX graph (opset 17, standard ops; the generator's STFT is Paradee's ConvSTFT: conv1d / conv_transpose1d with fixed DFT bases, matching the torch.stft it was trained with) with Kokoro's interface: `input_ids`, `style` [1, 256], `speed` in; `waveform` and `durations` (frames of 600 samples) out. Its durations equal the teacher's exactly. fp32 130-133 MB (the text side is 28.5M of the 33M parameters).
- **On the tablet**: `--tts-voice en=paradee:NAME`, a directory `{share}/paradee/NAME/` with `model.onnx` or only `model.ort` and `voice.bin` (straylight-voice branch `tts-distil-en`).

### Width sweep (English)

Cost per second of audio of the decoder alone, measured (`narrow.py`); the text side adds about 3 GFLOP/s. Tablet RTF from `straylight-listen --tts-bench` (6 threads, nice 5, next to the running service, 3 lines: 105, 157 and 81 tokens; untrained weights, since speed does not depend on them; `scripts/device-speed.sh`):

| Decoder | W / U, resblock kernels | Decoder params | Decoder GFLOP/audio-s | Tablet RTF (bench) |
| --- | --- | --- | --- | --- |
| teacher | 1024 / 512, [3, 7, 11] | 53.31M | 51.92 | 2.94 (Kokoro uint8) |
| x50 | 512 / 256, [3, 7, 11] | 15.47M | 13.13 | not run (over budget) |
| x40 | 416 / 208, [3, 7, 11] | 10.89M | 8.71 | not run |
| x35 | 352 / 176, [3, 7, 11] | 8.28M | 6.27 | not run (about 0.85 projected from x25's profile) |
| x25 | 256 / 128, [3, 7, 11] | 5.03M | 3.36 | 0.63-0.67; `--say-file` 0.69-0.73 |
| x35k2 | 352 / 176, [3, 7] | 7.43M | 4.23 | |
| x30k2 | 320 / 160, [3, 7] | 6.39M | 3.51 | 0.62-0.64 |
| x25k2 | 256 / 128, [3, 7] | 4.54M | 2.28 | 0.52-0.54 |
| x20k2 | 192 / 96, [3, 7] | 3.00M | 1.31 | 0.59-0.61 (noise; no faster) |

- **The CPU does not deliver the FLOPs these narrow graphs ask for.** x25 at about 6.4 GFLOP/s in all runs at RTF 0.65, about 10 GFLOP/s effective (Kokoro reaches 16-17). Tablet profile of x25 (`STRAYLIGHT_ORT_PROFILE`, `scripts/ort-profile.py`): generator 60 %, the teacher's text side 38 % (LSTM 13 %, BERT MatMul 13 %), trunk 2.5 %; by op: Conv 28 %, LSTM 13 %, MatMul 13 %, Sin 11 % (Kokoro's Snake activations at 4.8 kHz and 800 Hz, and the sine source), Add + Mul 13 %, InstanceNorm 4.5 %. The process keeps about 3.6 of the 6 cores busy; threads: 1 / 2 / 4 / 6 give RTF 1.75 / 1.10 / 0.78 / 0.72 (`--say-file`). One tablet thread is 15x slower than one laptop thread on this graph (4.3x for Kokoro): the small tensors and elementwise ops do not vectorise or thread as Kokoro's wide ones do.
- So the user's 6-8 GFLOP/s budget (x35-x40) would give RTF 0.85 or more on the CPU, over the 0.6 bar; only x25-class decoders fit, and with Kokoro-7M-Distill's two resblock kernels ([3, 7]) x25 is 20 % faster. The English sweep is therefore x25 ([3, 7, 11]) against x25k2 ([3, 7]); the wider points remain candidates for the GPU path (Radish), where the elementwise cost is cheap.

## Results

### The recipe that works

Stage 1 (20,000 steps): spectral losses plus **distillation of the teacher's iSTFT head** (L1 on its log-magnitude output, x1, and on the sine of its phase output, x2), with the student's harmonic source mixing copied from the teacher (`--teacher-source`: Kokoro runs the source under `no_grad`, so a student's mixing layer otherwise stays at its random initialisation) and the same random draws for both, so the teacher's head outputs are targets the student can match. Stage 2 (30,000 steps): MPD + multi-resolution spectrogram discriminators with feature matching, spectral losses x10, head distillation kept. Batch 16 x 64 frames, AdamW 2e-4, cosine. `scripts/lang-pipeline.sh` runs it unattended on a pod.

Without head distillation the narrow decoder is intelligible and spectrally close but sounds wrong to UTMOS: x25 after 6,000 spectral steps scored 1.25 (its PyTorch renders the same, so not the export), and adversarial training alone climbs slowly (held-out UTMOS 1.30 / 2.02 / 2.50 / 2.72 / 3.06 / 3.26 / 3.39 / 3.45 at GAN steps 2k-20k, the PGX run `narrow_x25_gan`). With head distillation and the teacher's source, stage 2 reached 4.23 by its step 4,000.

### English (af_heart), x25k2

Held-out lines (30), ONNX renders on the CPU; teacher = Kokoro fp32 (PyTorch):

| Voice | UTMOS | WER | CER | DTW mel L1 | LTAS diff (dB) | MFCC dist | 2-4 kHz harmonicity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| teacher (Kokoro fp32) | 4.51 | 1.6 % | 4.9 % | 0 | 0 | 0 | 4.16 dB |
| Kokoro uint8 (the tablet's engine) | 4.47 | 1.7 % | 5.6 % | 0.92 | 0.82 | 14.1 | 3.73 dB |
| student, stage 2 step 4,000 (fp32) | 4.23 | 0.3 % | 5.2 % | 0.38 | 0.69 | 1.46 | 0.71 dB |
| same, MatMul uint8 | 4.22 | | | | | | |
| same, all uint8 (QLinearConv too) | 1.25 | | | | | | |
| student, stage 2 step 8,000 (fp32) | 4.31 | | | | | | |
| **student, stage 2 step 28,000, MatMul uint8 (the pick)** | **4.40** | **0.8 %** | **5.3 %** | 0.43 | **0.47** | **0.92** | 1.87 dB |
| same, fp32 | | 0.5 % | 4.9 % | 0.33 | 0.46 | 0.93 | |
| Matcha LJSpeech (retired) | 3.94 | 1.4 % | 1.2 % | 1.05 | 4.51 | 29.2 | 3.67 dB |

- UTMOS over stage 2 (held-out, every 4,000 steps): 4.23, 4.31, 4.34, 4.36, 4.39, 4.37, 4.39 (steps 4k-28k); picked step 28,000.
- Speed is at the bar, not under it: RTF 0.60 median through the listener's own path (pieces of 32-220 characters), 0.50-0.52 in `--tts-bench` (whole lines). The text side (the teacher's PL-BERT, LSTMs and predictor, about 38 % of the time) is fixed; the remaining levers are the generator's Snake `Sin` (11 %) and its small-tensor elementwise ops, or the GPU.
- Brand lines: transcribed exactly as the teacher's are ("Welcome to AI Anne. ... AI Anne's assistant", "booked through AI and", "AI and can join"), no artefacts.
- My harmonicity measure stays low for the student (0.71 dB) although UTMOS and the timbre distances are close to the teacher; noted, not used as a gate.
- Quantisation: all-uint8 (QOperator, convolutions included) destroys the generator (UTMOS 1.25); quantising only the MatMuls (the teacher's PL-BERT and projections) keeps it (4.22) and is 4-7 % faster on the tablet; its durations differ from the teacher's by about 1 % (the duration head's matmuls are quantised).

Tablet (6 threads, nice 5, next to the running service; `scripts/device-distil.sh`, `--say-file` with the pacing sink, 6 lines; `.ort` files memory-mapped as installed):

| Model | RTF per line | First audio | Gaps | Peak RSS (speech process) |
| --- | --- | --- | --- | --- |
| fp32 | 0.60-0.64 | 1.01-1.75 s | 0.00-0.04 s | 307 MiB |
| MatMul uint8 | 0.56-0.61 (median 0.585) | 0.93-1.75 s (median 1.37) | 0.00 s | 268 MiB |
| **step 28,000, MatMul uint8 (the pick)** | **0.58-0.62 (median 0.60)** | **0.93-1.73 s (median 1.40)** | 0.00 s | 260 MiB |
| Kokoro uint8 (before) | 2.94-3.0 | 4.8-11.9 s | 4-21 s | 438-464 MiB |

In the live service (trial from tmpfs, 2026-11-04 02:35 JST, MatMul uint8 stage 2 step 8,000): loaded in 2.2 s, speech ready 17 s after the restart, RSS 1.26 GiB at rest (anon 567 MB, file 583 MB; it was 1.47 GiB with Kokoro and Piper resident), peak 1.29 GiB, MemAvailable 884-936 MB.

### Mandarin (zf_xiaoni*0.7+af_heart*0.3), x25k2

Held-out lines (23); teacher = Kokoro fp32 of the same blend:

| Voice | UTMOS | CER (tones) | DTW mel L1 | LTAS diff (dB) | MFCC dist |
| --- | --- | --- | --- | --- | --- |
| teacher | 4.23 | 2.9 % | 0 | 0 | 0 |
| Kokoro uint8 (laptop render of the tablet's engine) | | 2.9 % | 0.90 | 0.83 | 14.3 |
| student, stage 2 step 28,000 fp32 | | 2.1 % | 0.30 | 0.65 | 2.11 |
| **student, step 28,000, MatMul uint8 (the pick)** | **3.81** | **1.4 %** | 0.37 | **0.67** | **2.19** |

- UTMOS over stage 2: 3.43, 3.69, 3.71, 3.72, 3.76, 3.80, 3.81 (steps 4k-28k): a plateau 0.4 under the teacher, where English ended 0.1 under. UTMOS is trained on English speech, so it is the weakest of the measures here; the round trip (tones included) is better than the teacher's and the timbre distances are close. The brand lines are read as the teacher reads them (CER from the alias 诶爱安德 is the same for both).
- A wider decoder is not an option on the CPU: x30k2 (3.51 GFLOP/s) runs at bench RTF 0.62-0.64 on the tablet against x25k2's 0.53-0.55, which puts the speech path near 0.70.
- Tablet (speech path, 6 lines, MatMul uint8): RTF 0.54-0.55, gaps 0 (one 0.5 s), **first audio 1.2-2.9 s**: the splitter's first Chinese piece is a whole clause of up to 60 characters (the short first piece is for Latin script, and Japanese has its particle rule); Kokoro took 6-15 s, the Piper voice 0.7-2.0 s. A first-piece rule for Mandarin is the remaining fix.

### Japanese (jf_alpha*0.7+af_heart*0.3), x25k2

Held-out lines (23):

| Voice | UTMOS | CER | DTW mel L1 | LTAS diff (dB) | MFCC dist |
| --- | --- | --- | --- | --- | --- |
| teacher | 4.39 | 8.4 % | 0 | 0 | 0 |
| Kokoro uint8 (laptop render of the tablet's engine) | | 8.2 % | 0.66 | 1.52 | 11.0 |
| **student, stage 2 step 20,000, MatMul uint8 (the pick)** | **4.22** | **8.0 %** | 0.39 | **0.46** | **0.87** |

- UTMOS over stage 2: 3.72, 4.02, 4.14, 4.13 (steps 4k-16k), 4.22 at 20k; stopped there to save time (English gained nothing after 20k, Mandarin 0.05).
- Pitch accent (`streams/tts/scripts/rt-accent.py`, the 4 minimal pairs): the teacher itself separates 0 of 4 (misaki's Japanese phonemes carry no accent marks, so Kokoro is given the same string for 雨 and 飴), the student 1 of 4; its F0 is the teacher's own predictor's, so this is parity within the noise of the check.
- Tablet (speech path, 6 lines, MatMul uint8): RTF 0.54-0.57, first audio 1.08-1.51 s, gaps 0-0.18 s, peak RSS 291 MiB (speech process). Kokoro took RTF 2.95-3.15 and 5.9-12.3 s to first audio.

## Second round (2026-11-04): Japanese front end, Mandarin measures and teacher, misaki input

### A second quality measure: SHEET SSL-MOS

UTMOS (`utmos22_strong`) is trained on English listening tests only (BVCC), so a Mandarin or Japanese gap on it may be the predictor's, not the voice's. Second measure: **SHEET's SSL-MOS** (`unilight/sheet` v0.1.0 through torch.hub, "default" = `all7-sslmos-mdf-2337`, MIT; trained on seven MOS corpora: BVCC, SOMOS, SingMOS, NISQA, PSTN and two Mandarin ones, TMHINT-QI and Tencent), `scripts/sheet-mos.py` (on the PGX in the training image; its extra packages h5py, humanfriendly, prettytable and s3prl 0.4.18 go in `~/straylight-tts/pylib-sheet` with `PYTHONPATH`; s3prl's hub imports are made tolerant there because some of its unrelated upstreams fail to import with torchaudio 2.8). Evaluation only, nothing of it is in any shipped model.

It ranks the voices we have as UTMOS does, with a compressed top end (held-out lines):

| Voice | UTMOS | SHEET |
| --- | --- | --- |
| en student, GAN-only x25 step 2,000 | 1.30 | 1.80 |
| en student, GAN-only x25 step 10,000 | 2.72 | 3.22 |
| Matcha LJSpeech + Vocos (retired) | 3.94 | 4.09 |
| zh student, stage 2 step 4,000 / 12,000 / 28,000 (installed) | 3.43 / 3.71 / 3.81 | 4.37 / 4.57 / 4.62 |
| ja student, stage 2 step 4,000 | 3.72 | 4.57 |

Teacher against the installed students:

| | teacher UTMOS / SHEET | student UTMOS / SHEET | gap UTMOS / SHEET |
| --- | --- | --- | --- |
| en af_heart | 4.51 / 4.575 | 4.40 / 4.517 | 0.11 / 0.058 |
| ja (stage 2 step 20,000) | 4.39 / 4.660 | 4.22 / 4.645 | 0.17 / 0.015 |
| zh (stage 2 step 28,000) | 4.23 / 4.646 | 3.81 / 4.624 | 0.42 / 0.022 |

On the measure that has Mandarin in its training data, the Mandarin student is as close to its teacher as the English one (closer: 0.02 against 0.06), and per line it is within 0.06 of the teacher on all 23 held-out lines. So the 0.4 UTMOS gap is mostly UTMOS: it penalises something in the student's Mandarin that a predictor which has heard Mandarin does not. One seen line stands out: `zh-brand.seen` (欢迎来到ai&。我是ai&的助手，Straylight。) scores 3.66 against the teacher's 4.61 (every other line 4.58-4.66), worth a listen. The listening test is still to be done:

**Blind A/B set** (for the user): `/run/media/jethac/Shared/tts-distil-zh-ab/` (`clips/NN-A.wav`, `NN-B.wav`: 10 held-out lines, teacher Kokoro v1.0 fp32 against the installed student, levels matched, order random per pair; `README.txt` has the texts, `answers.tsv` the form). The key is kept apart in `/run/media/jethac/Shared/tts-distil-zh-ab-key/KEY.tsv`.

### Japanese: UniDic against NAIST

straylight-voice branch `tts-unidic` (worktree `/home/jethac/Projects/straylight-voice-unidic`, commit `a5ad438`): the Japanese front end reads either dictionary. UniDic's features have 29 fields, the pronunciation (`pron`, the field misaki reads) is field 9, then `kana` (20); NAIST's are 8 and 7; a `*` field falls through to the surface, so 、 and 。 stay pauses with UniDic too. Counter and clock readings are unchanged. The dictionary is `STRAYLIGHT_JA_DIC`, else `DATA/unidic/` if present, else `DATA/open_jtalk_dic/` (so the tablet is unchanged).

UniDic 3.1.0 (2021-08-31, the copy pip's `unidic` 1.1.0 downloads, as misaki uses) is offered under GPL-2, LGPL-2.1 or BSD-3-Clause at the user's choice (its `licenses/COPYING`); taken under **BSD-3-Clause** (copyright the UniDic Consortium). At run time it needs `sys.dic` 243 MB, `matrix.bin` 481 MB (18,551 x 20,858 connection costs), `char.bin`, `unk.dic`, `dicrc`: about 725 MB, against NAIST's 65 MB, and the tablet's root has 274 MB free.

Phonemes for the 25 ja eval lines and the 8 accent minimal pairs both ways, rendered by the teacher (Kokoro v1.0 fp32, the persona blend, same seeds; `/run/media/jethac/Shared/tts-distil-unidic/`):

| Front end | UTMOS | SHEET | CER (held-out) | accent pairs separated | vs Python misaki, punctuation ignored |
| --- | --- | --- | --- | --- | --- |
| NAIST (shipped) | 4.391 | 4.660 | 8.4 % | 0 / 4 | 9 / 23 identical, PER 2.6 % |
| UniDic | 4.380 | 4.660 | 8.1 % | 0 / 4 | 23 / 23 identical, PER 0.0 % |

- **A tie.** UTMOS 0.01 apart, CER 0.3 points apart on 23 lines (one or two characters of ASR noise), pitch accent the same (the accent strings are identical except 二本, which UniDic reads に ポン). With UniDic, our front end gives exactly misaki's phonemes apart from the kept punctuation and the brand lexicon entry (all-lines PER against misaki 5.1 % with punctuation, 7.6 % for NAIST).
- **Readings where they differ** (the 16 lines with any difference): NAIST is wrong on 九時 (きゅうじ, twice), 七時 (ななじ), 四十分 (よんじゅうふん, twice), 通用口 (つうようこう); UniDic is wrong on 木曜日 and 水曜日 (もくようひ, すいようひ: every weekday), 四番 (よばん), 十二分, 五分, 二十五分 (ぷん), 二本 (にぽん). Others are style: UniDic writes long vowels as pronounced (ストレー, いう as ユー, 聞いて キーテ). Six clear errors each; the weekday is the most frequent word in assistant replies, the kanji clock times the next. (Numbers written in digits go through our counter rules with either dictionary; these lines spell numbers in kanji, which the dictionary reads.)
- ASR spot checks on the teacher renders: NAIST's 午後二時半 split as ɲi ʥihaɴ was heard as 午後に自販 and its 車で as 来るまで; UniDic's 木曜日 was heard as 目標日, 水曜日 as 水用費, and its 一時間 as 位置時間.
- **Decision: NAIST stays** (not clearly better, and 725 MB does not fit on root). UniDic support is kept for misaki-compatible phonemes (the Hugging Face card) and in case root grows (`stage-b`). Both dictionaries' kanji-numeral clock and counter errors could be fixed in the front end by extending the digit counter rules to kanji numerals; not done.

### Japanese student, full stage 2

So the Japanese student is the same recipe on the same (NAIST) phonemes, now with the whole stage 2: the first run's stage 2 stopped at 20,000 of 30,000 steps without its `last.pt` (the PGX pulls exclude it), so it could not be resumed; stage 2 was run again from the start (30,000 steps from stage 1's step 20,000 snapshot, which was copied to the pod; `lang-pipeline.sh` now skips stage 1 when that snapshot exists, `S2TAG=_s2b` names the run, `KD_THREADS` pins the corpus workers' threads). Pod `tts-distil-ja3`: the teacher corpus (35 shards, 4 workers, 3 threads each) in 27 min, stage 2 at 0.14 s a step.

Held-out UTMOS over the new stage 2 (fp32 exports, every 2,000 steps): 3.31, 3.68, 3.98, 3.96, 4.08, 4.15, 4.17, 4.20, 4.18, 4.18 (20k), 4.23, 4.23, 4.22, 4.22, 4.22 (30k). The first run had 4.22 at 20k (fp32), so the last third of the schedule adds little: the Japanese student plateaus about 0.15 under its teacher on UTMOS, where English ends 0.1 under.

| Voice | UTMOS | SHEET | CER | DTW mel L1 | LTAS diff (dB) | MFCC dist | accent pairs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| teacher | 4.39 | 4.660 | 8.4 % | 0 | 0 | 0 | 0 / 4 |
| installed: first run, step 20,000, MatMul uint8 | 4.22 | 4.645 | 8.0 % | 0.39 | 0.46 | 0.87 | 1 / 4 |
| new run, step 24,000, MatMul uint8 | 4.24 | 4.648 | 8.4 % | 0.38 | 0.36 | 0.95 | |
| new run, step 30,000, fp32 | 4.22 | 4.649 | 8.0 % | 0.29 | 0.34 | 0.92 | |
| **new run, step 30,000, MatMul uint8 (the pick)** | **4.26** | **4.648** | **8.0 %** | 0.38 | **0.38** | **0.85** | 0 / 4 |

- **The pick: step 30,000, MatMul uint8**: best UTMOS (gap to the teacher 0.13, was 0.17), SHEET gap 0.012, recognition as before and under the teacher's, timbre a little closer. A small, consistent gain, not a step change. The uint8 model is calibrated on the first 24 training-corpus lines (`quantize-narrow.py ... src/corpus/ja.phon.tsv --ops MatMul`).
- Same graph and size as the installed voice (x25k2, 109 MB `.ort`), so tablet speed and memory are unchanged (RTF 0.54-0.57); the voice vector is the same bytes. Packed for the tablet in `work/voices/ja-alpha-v2/` (`model.ort` SHA-256 `115c7a2a…`, `voice.bin` `96be34a5…`, git-ignored); export on the PGX `~/straylight-tts/export/narrow-ja-x25k2_s2b-0030000-u8mm/`, checkpoints `paradee/ja/checkpoints/narrow_x25k2_s2b/`, pod logs `logs/pods-ja-run2/` (the first run's in `logs/pods-ja-run1/`). Not installed: replacing `/usr/local/share/straylight-listen/paradee/ja-alpha/` with it is the integrator's step.
- Pitch accent stays the teacher's limit (its phonemes have no accent marks): the teacher separates 0 of 4 pairs, the new student 0 of 4 (the first run's 1 of 4 was within the check's noise).

### Mandarin teacher: Kokoro-82M v1.1-zh

`hexgrad/Kokoro-82M-v1.1-zh` (`kokoro-v1_1-zh.pth`, SHA-256 `b1d8410fa44dfb5c…`, as the card states; on the PGX in `~/straylight-tts/downloads/hexgrad-v1.1-zh/` with its 103 voices).

- **Licence and data** (model card): weights Apache-2.0. Training data: "100 Chinese speakers from a professional dataset", "freely and permissively granted to us by LongMaoData" (the grant's terms are not published), plus "crowdsourced synthetic English data" (1 h each of Maple, Sol, Vale) whose source is not named; the card adds "Since this synthetic data is crowdsourced, the model trainer is not bound by any Terms of Service". v1.0's card describes its data the same way (permissive and synthetic audio), so the weights are as clean as v1.0's; the new part is a third party's grant with unpublished terms and synthetic English of undisclosed origin. Our text side of the chain is unchanged (our CC0 / public-domain text would be rendered by it).
- **Front end**: misaki's `ZHG2P(version='1.1')` (`zh_frontend.py`: jieba with part-of-speech tags, pypinyin, PaddleSpeech's **tone sandhi** (third tone, 一, 不), erhua), output as zhuyin-like symbols with tone digits (a new vocabulary). Examples on the eval lines: 一个 ㄧ2ㄍㄜ5, 一遍 ㄧ2ㄅ言4, 一点 ㄧ4ㄉ言3, 对不起 ㄅㄨ5, 两点 ㄌ阳2ㄉ言3 (v1.0: i→pjɛ↘n, lja↓ŋtjɛ↓n). Our Rust front end is the v1.0 path; v1.1 would need a new port (tone sandhi needs jieba's POS tags; jieba-rs has them).
- **Voices**: 103 (zf_001-zf_099 with gaps, 55 female; 45 male zm_*; af_maple, af_sol, bf_vale); af_heart and zf_xiaoni are not in it, and v1.0 voice packs do not belong to its style space, so the persona blend does not carry over. Closest to the persona (v1.0 zf_xiaoni*0.7+af_heart*0.3) over 5 lines, all 55 zf voices and some blends (`scripts/v11-voices.py`; the card's speed curve, which slows inputs over 83 phonemes because the model rushes them): zf_048 (MFCC 10.0, LTAS 4.2 dB, F0 237 Hz), zf_024 (11.1, 3.4 dB), zf_032, zf_059; best blend zf_048*0.5+zf_024*0.5 (MFCC 8.4, LTAS 3.2 dB, F0 229 Hz, the persona's is 229). For scale, the installed student is 0.67 dB / 2.2 from its teacher: every v1.1 candidate is a different voice, not the persona.
- **25 zh eval lines** (misaki 1.1 phonemes, brand and name through our lexicon's aliases):

| Teacher, voice | UTMOS | SHEET | CER (held-out) | duration vs v1.0 | LTAS / MFCC to the persona |
| --- | --- | --- | --- | --- | --- |
| v1.0 zf_xiaoni*0.7+af_heart*0.3 (today) | 4.23 | 4.646 | 2.9 % | 1 | 0 |
| v1.1 zf_048*0.5+zf_024*0.5 | 4.07 | 4.652 | 0.8 % | 1.19 | 3.16 dB / 8.4 |
| v1.1 zf_048 | 4.05 | 4.657 | 1.3 % | 1.29 | 3.94 dB / 9.9 |
| v1.1 zf_047*0.7+af_maple*0.3 | 4.15 | 4.644 | 1.3 % | 1.06 | 2.67 dB / 14.0 |
| v1.1 zf_001 (the card's sample voice) | 3.71 | 4.674 | 1.3 % | 1.03 | 4.52 dB / 22.6 |

- **Not a clear win, so no retrain was run.** Recognition is better (CER 0.8-1.3 % against 2.9 %; tone sandhi), naturalness the same on SHEET and lower on UTMOS, and the voice is no longer the persona. Shipping it also needs the v1.1 front end ported to Rust before the student's phonemes match the device's, and the card's speed curve in the listener. The installed v1.0 student already transcribes at 1.4 %.
- **Proposal** (for the user): if better tones are wanted, (1) port misaki's v1.1 Mandarin front end (zh_frontend + tone sandhi + erhua) to `zh.rs`; (2) choose a v1.1 voice by listening (zf_048*0.5+zf_024*0.5 is the closest measured; the persona's blend cannot be kept); (3) render the zh corpus with v1.1 and train the x25k2 student with v1.1's text side (same recipe, one 5090-class pod, about 1.5 h); (4) record LongMaoData's grant and the synthetic-English provenance on the card. Before that, the A/B set above tells whether the current student is already good enough.

### misaki phonemes into the students (for the model card)

Python misaki 0.9.4 phonemes (Kokoro's `KPipeline`: en `G2P` with espeak-ng fallback, ja `JAG2P` with UniDic, zh `ZHG2P` v1.0) for the raw eval texts (so the brand as misaki reads it), into the installed students and the teacher (`/run/media/jethac/Shared/tts-distil-misaki/`). Our front end's numbers for comparison (held-out lines):

| | front end | teacher UTMOS / SHEET / CER | student UTMOS / SHEET / CER |
| --- | --- | --- | --- |
| en | ours | 4.51 / 4.575 / 4.9 % (WER 0.5 %) | 4.40 / 4.517 / 5.3 % (WER 0.8 %) |
| en | misaki | 4.51 / 4.574 / 5.3 % (WER 0.5 %) | 4.40 / 4.516 / 5.1 % (WER 0.8 %) |
| ja | ours (NAIST) | 4.39 / 4.660 / 8.4 % | 4.22 / 4.645 / 8.0 % |
| ja | misaki (UniDic) | 4.35 / 4.658 / 9.6 % | 4.18 / 4.646 / 11.1 % |
| zh | ours | 4.23 / 4.646 / 2.9 % | 3.81 / 4.624 / 1.4 % |
| zh | misaki | 4.23 / 4.645 / 3.4 % | 3.81 / 4.625 / 2.1 % |

- WER and CER of both rows re-measured together on 2026-11-04; the teacher's English WER measures 0.5 % now on the same renders that gave 1.6 % above (eval.py's English normalisation changed in between), the students' are unchanged.
- The students take misaki's phonemes as well as the teacher does: naturalness unchanged in every language. English is the same either way. Japanese from misaki is 8 % shorter (misaki drops every 、 and 。, so no pauses) and recognised less well (11.1 % against 8.0 %; the brand line's "ai &" adds to it). Mandarin from misaki loses a little (2.1 % against 1.4 %), mostly the brand and the name spelled as letters.
- For the card: the voices accept misaki's output directly; with our front end Japanese keeps its pauses and counter readings.

## Evaluation

Lines: `cases/eval-lines.tsv`, assistant-style replies written for this (32 en, 25 ja, 25 zh); the greeting and the first brand line are also in the training corpus (ids ending `.seen`, summarised apart), all others are held out. Phonemes from the device front end (`straylight-listen --g2p` with the shipped lexicon), so the brand is read as the lexicon says (en `ˌAˌIˈæːnd`).

- **WER / CER**: Qwen3-ASR-0.6B Q8_0 (transcribe.cpp) round trip, `scripts/eval.py`; English WER with digits spelled out first and "AI" counted as "A I".
- **UTMOS**: SpeechMOS `utmos22_strong` v1.2.0 (`scripts/utmos.py`, on the PGX in the training image).
- **Timbre**: against the teacher's renders, all of a voice's files pooled: RMS difference of the level-normalised long-term average spectrum (64 mel bands, dB) and the distance of the mean MFCC 1-12 (as `streams/tts/scripts/kokoro-voices.py`); also DTW mel L1 and log-spectral distance per line.
- **Teacher renders** (`eval/kokoro-<lang>`): Kokoro-82M fp32 (PyTorch, the PGX) from the same phonemes and style row.
- Japanese pitch accent: `streams/tts/scripts/rt-accent.py` on the minimal pairs (`work/accent-ja.phon.tsv`); Mandarin tones: the ASR round trip's CER.

Baselines (English, 30 held-out lines):

| Voice | UTMOS | WER | CER | LTAS diff (dB) | MFCC dist | DTW mel L1 |
| --- | --- | --- | --- | --- | --- | --- |
| Kokoro af_heart fp32 (teacher, PyTorch) | 4.51 | 1.6 % | 4.9 % | 0 | 0 | 0 |
| Kokoro af_heart uint8 (the tablet's engine, laptop render) | 4.47 | 1.7 % | 5.6 % | 0.82 | 14.1 | 0.92 |
| Matcha LJSpeech + Vocos (retired as "insanely bad") | 3.94 | 1.4 % | 1.2 % | 4.51 | 29.2 | 1.05 |

WER does not separate the retired voice from Kokoro (it is perfectly intelligible); UTMOS and the timbre distances do. Teacher UTMOS for ja and zh: 4.39 and 4.23.

Japanese and Mandarin (23 held-out lines each): teacher (fp32) CER 8.4 % (ja) and 2.9 % (zh), UTMOS 4.39 and 4.23; the tablet's uint8 Kokoro CER 8.2 % and 2.9 %, LTAS diff 1.52 / 0.83 dB, MFCC distance 11.0 / 14.3 from the teacher (laptop renders; the uint8 model's own quantisation and noise draws account for this "distance" between two runs of the same voice).

## Paradee's own student (superseded)

Tried first on 2026-11-03 and stopped after the change of plan (text side `checkpoints/text_s+mlp` 8,000 steps, held-out DTW log-mel 0.69 through the teacher decoder; decoder A to about 4,000 steps): its learned constant voice and narrow text side are replaced by the teacher's text side and style. Its scripts stay the base of the narrow student (data, losses, discriminators, ConvSTFT).

Source: Paradee (Sahil Mahendrakar, arXiv:2610.06817; `git@github.com:sahilmahendrakar/paradee.git` at `aae3cc46`, cloned to `downloads/paradee/src`). Code and released weights are Apache-2.0, but the released weights were trained on WikiText-103 sentences (CC BY-SA 3.0), so they are **not used, not even as a starting point**: every student here is trained from scratch on our own CC0 / public-domain corpus, with the recipe only. oddadmix/Kokoro-7M-Distill (Apache-2.0) was read for its lessons (the voice's exact style vector is part of the model; rank on UTMOS and WER together; snapshot often, the best checkpoint is often mid-run), not used.

What it is: Kokoro's own modules at small widths, trained half by half against the frozen teacher, with no alignment learning:

- Text side (`student.py`, preset `s+mlp`, 4.23M parameters): Kokoro's ALBERT, prosody predictor and text encoder, narrower, with one learned style vector (the voice is built in); learns the teacher's durations, F0, energy and phoneme features directly.
- Decoder: Kokoro's AdaIN trunk at 256 channels (preset `A`), then (Paradee 1.1) a frame-rate source-filter head (`vhead.py`, head `v2`): a sine bank built from F0 with a predicted smooth gain and phase per harmonic band, plus shaped noise (plain, pitch-pulsed and a short-window burst path). No upsampling network and no phase-locking post-filter (1.1 replaced the 1.0 filter). Upstream: 7.88M parameters in all, 8.5 MB as int8, about 3.4 GFLOP per second of audio.
- One ONNX graph, `input_ids` and `speed` in, waveform out; our export (`export_paradee_v1_1.py` patched by `scripts/paradee/setup.sh`) also outputs each token's duration in 600-sample frames, so it has Kokoro's interface and spoken-character timing works as with Kokoro.

Adaptation (`scripts/paradee/`):

- `kd_teacher.py`: the teacher corpus from our sentences and the device front end's phonemes (the same `corpus/<lang>.phon.tsv` as the Matcha renders), in our voice (a name or a blend, the style row `pack[n - 1]` as the tablet uses), storing what upstream `gen_teacher.py` stores; rows shuffled (seed 1) so the 200 held-out rows of shard 0 cover every source; the harmonic source's STFT on the CPU and a fixed seed per row (so no separate `regen_audio.py` pass).
- `teacher_shim.py`: stands in for `kokoro.KPipeline` (misaki is not installed and not used): our Kokoro build, and every voice the scripts ask for is `PARADEE_VOICE`, so their hard-coded `af_heart` becomes our blend for ja and zh.
- `setup.sh`: one working directory per voice on the PGX (`~/straylight-tts/paradee/<lang>/`) with the pinned upstream scripts, patched for CUDA, the shim and the durations output. `run.py` applies the GPU memory fraction, TF32 and cuDNN autotuning.
- Schedule, changed for time: upstream trains decoder A for 50,000 steps plus two GAN stages (10,000 steps) and then the 1.1 head (40,000 + 15,000 GAN). On the shared GB10 decoder A costs 0.8-1.0 s a step (its upsampling generator; measured with `--profile`: forward 0.28 s, backward 0.55 s) and the head 0.34 s, so decoder A is run only as a warm-up for the trunk (about 10,000 steps) and the 1.1 head's two stages then train trunk and head together from it.

## RunPod (from 2026-11-03)

Budget about $75 of an $88 balance (spend limit $80). The API key stays on stadia-testbed (`~/tts-distil-rp.sh gql|rest ...` reads it from Bitwarden Secrets Manager in an interactive shell); pods are driven from the PGX, whose key is the pods' `PUBLIC_KEY` (the laptop cannot log in to them).

- **Stock** (2026-11-03 15:00-16:00 UTC): GraphQL `podFindAndDeployOnDemand` failed for every single type asked (RTX 4090/5090/3090, L40S, community and secure, also with no CPU, RAM or port constraints) with `"There are no longer any instances available with the requested specifications. Please refresh and try again."` (`SUPPLY_CONSTRAINT`): `lowestPrice.stockStatus` showed only a few types with any stock (secure: RTX 3090, RTX 5090, H100 SXM, L4, RTX PRO 4500, RTX PRO 6000 Server; community: RTX 3070), and those few are taken fast. The REST API (`POST /pods` with a list of acceptable `gpuTypeIds`) found an RTX 5090; a second REST call with only the large cards (RTX PRO 6000 Blackwell variants, H200, B200, H100 SXM/NVL, RTX 6000 Ada) found an RTX PRO 6000 Blackwell Server Edition. At that moment the large types all showed no stock in the GraphQL listing.
- **The PGX's uplink is slow** (about 60 KB/s to the pods), so corpora are not uploaded: `scripts/pod-setup.sh` sends our code and phoneme lists (a 2 MB tarball); the pod fetches Kokoro-82M v1.0 from Hugging Face (SHA-256 of `kokoro-v1_0.pth` and `config.json` checked against the PGX copy: `496dba118d1a…`, `5abb01e2403b…`), Paradee from GitHub at `aae3cc46`, the pip packages, and renders its own teacher corpus from the same phonemes. Only our corpus goes up.
- **CPU threads** were the bottleneck, not the GPU: PyTorch started 64 threads in a 13.6-CPU quota (and 20 in the PGX containers' 4), so the CPU part of every step thrashed while the GPU idled between bursts. `run.py` now pins them (the cgroup quota, at most 8). Also moved to the GPU: the generator's STFT (`ConvSTFT`, the exported graph's own, instead of `torch.stft` on the CPU) and the collate's alignment (index expansion of the segment only, instead of a dense matrix product per sentence). On the 5090, head distillation at batch 16: 1.30 s a step before, 0.91 with the GPU STFT and collate, 0.32 with 8 threads pinned.
- The RTX PRO 6000 pod's GPU showed 48 GB in use and load from a process outside our container, and its host's load average was 87-155: a Japanese teacher shard took 615 s there against 80 s on the 5090.

Speed per step on x25k2 (2 shards, 150 steps; after the thread fix; the 5090 alone, the RTX PRO 6000 with the ja and zh teacher corpora rendering on it and an outside tenant):

| GPU | $/h | stage 1 (spectral + head distillation) b16 / b32 | GAN b8 / b16 / b32 | GAN + head distillation b16 | teacher corpus, s per 500-row shard |
| --- | --- | --- | --- | --- | --- |
| RTX 5090 (secure) | 1.19 | 0.11 / 0.16 | 0.12 / 0.19 / 0.33 | 0.22 | 80-100 (one worker) |
| RTX PRO 6000 Blackwell Server 96 GB (secure) | 2.49 | 0.36 / 0.58 | 0.54 / 0.54 / not run | not run | 615 |
| GB10 (the PGX, shared, before the thread fix) | 0 | 0.91-1.13 (b16) | 1.0-1.7 (b8) | | 100 (alone) to 900 (shared) |

Larger batches cost almost proportionally more per step on the 5090 (no free throughput), so the runs keep batch 16; packing a second job on one 5090 (English stage 1 with three corpus workers) ran stage 1 at 0.13 s a step instead of 0.11. The PRO 6000 was terminated after the measurement (3x slower than the 5090 at twice the price).

Fleet (2026-11-03 16:30 UTC): one pod per language, each running `scripts/lang-pipeline.sh` unattended (teacher corpus with parallel `KD_PART` workers, stage 1 20,000 steps, stage 2 30,000), snapshots pulled to the PGX every 5 minutes by `scripts/pull-pods.sh` and evaluated there (`scripts/watch-eval.sh`, CPU).

| Pod | GPU | $/h | Started (UTC) | Stopped | Jobs |
| --- | --- | --- | --- | --- | --- |
| `tts-distil-en` (x2romeyeanbmbp) | RTX 5090 32 GB, secure | 1.19 | 11-03 14:52 | 11-03 18:46 (terminated) | en corpus, speed tests, en student |
| `tts-distil-big` (kommkwy1aai2k5) | RTX PRO 6000 Blackwell Server 96 GB, secure | 2.49 | 11-03 15:20 | 11-03 16:24 (terminated) | speed tests |
| `tts-distil-zh` (e4c3rnfk639ytk) | RTX 5090 32 GB, secure | 1.19 | 11-03 16:20 | 11-03 19:07 (terminated) | zh corpus and student |
| `tts-distil-ja` (o0eyp6mmcmzbux) | RTX A6000 48 GB, secure | 0.59 | 11-03 16:28 | 11-03 17:20 (terminated) | ja corpus from the first shard up (about 5 min a shard with 4 workers) |
| `tts-distil-ja2` (m3krjt4k1wo7nk) | RTX 4090 24 GB, secure | 0.89 | 11-03 16:58 | 11-03 19:48 (terminated) | ja corpus from the last shard down (`KD_REVERSE=1`), shards exchanged with `tts-distil-ja` by `scripts/sync-shards.sh`; then the ja student |

Second round (2026-11-04): GraphQL stock showed no RTX 5090; REST `POST /pods` with the list RTX PRO 6000 Blackwell Workstation, RTX 5090, H100 SXM, H200, RTX PRO 6000 Server, RTX 4090 (`gpuTypePriority: custom`, secure, 12+ vCPU) gave pod `tts-distil-ja3` (wqpicfxjq78xn7), **RTX PRO 6000 Blackwell Workstation Edition, $2.59/h**, 16 vCPU (13.6 CPU quota), 03:46-05:44 UTC: setup, the ja teacher corpus in 27 min (4 workers x 3 threads), stage 2 at **0.14 s a step** (the 5090 took 0.22, the outside-tenant Server Edition 0.54), 30,000 steps in 70 min. Balance $74.20 before, $69.45 after: **$4.75**. Pod deleted, no network volumes.

Spend: $4.34 by 2026-11-03 16:11 UTC (balance $84.38); $5.73 by 16:35 (fleet $2.99/h); $8.27 by 17:20; $12.95 by 18:46 (English pod terminated after its run; $2.09/h for zh and ja2); **$14.51 in all** when the last pod was terminated at 19:48 (balance $74.21, no pods, no network volumes).

## The PGX

`ssh -o HostName=thinkstationpgx-00b4 pgx` (tailnet; the `.local` name in the SSH config only resolves on the LAN). Shared machine: other GPU jobs run there, so `scripts/pgx-run.sh` starts one detached container with nice 10, 48 GB RAM, 6 CPUs and a GPU memory fraction, with `~/straylight-tts` mounted at `/w`. Never touch processes that are not ours.

## Licence chain

Text: CC0 and public domain only (Common Voice sentence lists, Aozora Bunko, our own assistant lines; sources recorded per sentence by `scripts/build-corpus.py`). Teacher: Kokoro-82M v1.0 and its voices (Apache-2.0), fetched from Hugging Face at the same bytes as the PGX copy. Students: Kokoro's own text-side weights (Apache-2.0) plus a decoder trained here only from the teacher's renders and internals of that text; code from Kokoro (Apache-2.0) and Paradee (Apache-2.0, training scripts only: its released weights, trained on WikiText-103 sentences under CC BY-SA 3.0, are not used). Matcha-TTS and Vocos (MIT) only in the fallback. No third-party recordings; only our corpus went to RunPod.

Added 2026-11-04: UniDic 3.1.0 (BSD-3-Clause, of its GPL/LGPL/BSD choice; the UniDic Consortium), supported by the front end but not shipped. Evaluation only, in no model: SHEET (`unilight/sheet` v0.1.0, MIT; its released `all7` checkpoint) with s3prl 0.4.18 (Apache-2.0), h5py (BSD), humanfriendly (MIT), prettytable (BSD); DNSMOS (Microsoft DNS-Challenge, CC BY 4.0) was downloaded to `/run/media/jethac/Shared/tts-distil-downloads/dnsmos/` and not used. Kokoro-82M-v1.1-zh (Apache-2.0; data terms above) only evaluated.

## Left on the device

Nothing: the English trial (branch binary, conf with `--tts-share /dev/shm/distil-share --tts-voice en=paradee:en-heart`, voice in tmpfs) was reverted on 2026-11-04 04:51 JST (`scripts/device-voice.sh revert-trial`): the original binary and `/etc/straylight-listen.conf` (`en=kokoro:af_heart`, zh Piper as before) are back, `/dev/shm/distil*` removed, the service active. The bench payloads in `/dev/shm/distil` were removed (`scripts/device-distil.sh clean`).
