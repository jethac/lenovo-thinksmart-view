# Voice pipeline: wake word, recognition, screen

On-device speech recognition wired into the Straylight voice assistant: "Hey Straylight", then what the user says appears phrase by phrase on the Captions screen, the final request on Thinking, a placeholder reply on Speaking, then Idle. The chatbot (ai&'s servers) and speech output are not part of this stream.

The code is in the straylight-voice repository (`github.com/jethac/straylight-voice`, commit `7223e53`): `listen/asr/` (the recogniser, C++ behind a C API, with transcribe.cpp's build and patches), `listen/src/` (`asr.rs`, `responder.rs`, the screen flow in `main.rs`), `listen/packaging/`. Its `listen/README.md` has the design and the measurements in full; this file has the summary, the test method and the device state.

## What runs

- `straylight-listen.service` (one process): capture (`hw:0,1`) and the wake-word detector as before; on a wake, Silero VAD v6.2 and the ASR stream's tuned segmenter (thresholds 0.5/0.35, 300 ms pause, 1 s minimum phrase, 800 ms long pause, 6 s split at the quietest frame, 200 ms padding) on the audio thread; one worker thread running Qwen3-ASR-0.6B (`Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf`) on 6 threads at nice 5, each phrase with the text so far as context, language detected per phrase.
- transcribe.cpp at `5700f127` with `streams/asr/patches/0001` and `0002` (copied into straylight-voice `listen/asr/patches/`), built as static archives by `listen/asr/build.sh` (Cortex-A53, NEON, no OpenMP, PIC) and linked into the Rust binary (`--features asr`). Both models are memory-mapped at start, touched by a warm-up run, and stay resident.
- **Incremental conv stem: used.** It fits the one-run-at-a-time rule cleanly because the worker owns the session: when it is free while a phrase is being spoken (the usual case, and then the context is complete), it starts that phrase as a stream and feeds it every 250 ms, but only audio certain to be inside the phrase (never past a pause that has begun, never past the earliest point a 6 s split could cut), so the result is exactly `transcribe_run` on the phrase. A phrase cut while the worker is still busy runs whole with `transcribe_run`. Measured: 0.65-0.7 s less lag per phrase than whole phrases.
- Screen flow and its messages: listen/README.md "The screen flow". End of request: 1 s of VAD silence after a real phrase (blips and the wake word's tail do not count), not before 2.5 s after the wake, 5 s if nothing is said, 15 s at most; all in `/etc/straylight-listen.conf`.
- `Responder` trait (`listen/src/responder.rs`), `Echo` installed: `[ai& is not connected yet] You said: “…”` in the request's language (ja/zh variants), streamed in two pieces; Speaking advances `spoken_chars` at 15/7/5 chars per second (en/ja/zh).

## Measurements (device, 2026-10-31)

Test set (`scripts/make-testset.py`, `work/testset/`): per command clip of `../asr/work/testset/cmd-{en,ja,zh}` (15 each), 0.5 s of room noise, a held-out Magpie "Hey Straylight" in the same language (`../wakeword/work/clips/magpie-pos-test-<lang>`), a 350 ms pause, the command, 2.5 s of noise; everything at -22 dBFS; 16 kHz mono and 48 kHz stereo. Demo requests (`scripts/make-demo.py`, from Magpie speaker 4 on the laptop): "Hey Straylight, what's the weather tomorrow?" in English, Japanese and Mandarin.

- File input (`scripts/device-file.sh`): `straylight-listen --input ... --realtime` through the whole pipeline with the screen, as a transient unit with the service's limits, the service stopped meanwhile.
- Acoustic (`scripts/device-acoustic.sh`): the 48 kHz clips through the tablet's speaker (`aplay -D hw:0,0`, amp 187 = -10 dB as the wake-word loopback, restored to 145), the installed service listening on its mics with `--asr-gain 12`. 15 test clips plus the 3 demos and 3 more clips, one at a time.
- `scripts/summarise.py LOG [--per-utt] [--only REGEX]` scores and summarises; logs in `work/results/`.

File input, 45 requests, 6 threads, streaming (`file3-t6`), medians:

| | en | ja | zh |
| --- | --- | --- | --- |
| woke | 15/15 | 15/15 | 13/15 |
| wake to Captions | 0.57 s | 1.96 s | 0.94 s |
| wake to first caption text | 6.9 s | 11.5 s | 10.6 s |
| caption lag (end of phrase speech to text) | 4.36 s | 6.38 s | 6.21 s |
| end of speech to Thinking | 4.37 s | 6.47 s | 6.21 s |
| accuracy | WER 2.08 % | CER 13.8 % | CER 2.53 % |
| language right | 15/15 | 17/18 phrases | 13/13 |

Same 15 requests, acoustic vs file: woke 13/15 vs 14/15; en WER 5.3 vs 3.7 %, ja CER 7.2 vs 5.6 %, zh CER 1.45 vs 1.45 %; acoustic caption lag 3.94 / 6.23 / 5.87 s, end of speech to Thinking 3.95 / 6.24 / 5.88 s.

Demo, acoustic: "what's the weather tomorrow" → Captions 0.30 s after the wake, `What's the weather tomorrow?` 5.0 s after it, Thinking 3.5 s after the end of speech; Japanese `明日の天気はどう。` 4.4 s; Mandarin `明天天气怎么样？` 3.4 s.

Variants (file input, 45 requests, caption lag en/ja/zh; blocks over 20 ms): 6 threads streaming 4.36/6.38/6.21 s, 11; 7 threads 3.97/5.62/5.62 s, 21; 6 threads whole phrases 5.03/6.91/6.95 s, 98. 6 is installed: 7 is 10 % faster but doubles late audio-thread blocks.

Wake detector during ASR: live (19 acoustic requests) longest audio-thread block 19.0 ms, none over 20 ms, capture backlog at most 1 block, no ALSA overrun. File mode: longest 29 ms, 11 of about 26,000 blocks over 20 ms (one earlier run: 47 ms, 18); the capture queue (1.28 s) absorbs these, no audio lost.

CPU: idle 11.9 % of one core (unchanged). Per request 28/51/40 s of process CPU (en/ja/zh): 6 cores busy while a phrase is transcribed (ggml busy-waits), about 3 cores averaged over a request, nothing after.

Memory (model pages charged to the unit: service restarted after `drop_caches`): idle cgroup 932 MiB (562 MiB model file pages, 366 MiB anonymous), RSS 918 MiB; peak 954 MiB live, RSS peak 1013 MiB in file-mode runs with 5-6 s phrases. Unit: `MemoryMax=1300M` (the rest keeps at least 640 MiB; it uses about 250), `MemoryLow=1000M`, `MemorySwapMax=0`, `OOMScoreAdjust=500`. MemAvailable with everything running 1.3 GiB. No OOM event in any run (cgroup `memory.events` all zero, nothing in the kernel log).

Where the time goes: the decoder, 2.9-4.5 s per phrase (prefill of audio tokens and prompt, then ~100 ms per token), against 0.75-1.2 s of encoder left after the streamed conv stem. A short command still waits about 3.5-4.5 s after its end; long Japanese/Mandarin sentences 6 s. The ASR stream's "Next" items (shorter prompt, cached prompt prefix, lower-bit output head, speculative decoding) are what would move this.

## Compromises and known issues

- Caption lag is 4-6 s per phrase on this CPU (as the ASR stream predicted); Captions shows "· · ·" (pending) meanwhile.
- The wake word's tail can come out as a fragment (`哦。`) when the Magpie clip's "ト" runs on past a short dip; speech going on at the wake point is skipped to its first pause unless it lasts 400 ms (`--wake-tail-ms`), which fixed two of three cases in the Japanese set. A command said straight after the wake word with no pause is kept whole (checked on the laptop build with the pause removed from 5 requests).
- Japanese CER 13.8 % on file input is the model's homophones plus that fragment and one clip with 2.5 s of noise before the first word; the ASR stream's whole-clip Japanese CER was 6.5-7.3 %.
- `--asr-gain 12` is set for the mic path (user speech about -45 dBFS at arm's length; without it Silero missed a quiet "Stop." in one of the user's recordings, laptop build). File-input runs used 0 dB (the files are at -22 dBFS).
- ggml's compute threads inherit nice 5 from the worker (Linux per-thread nice is copied at clone); checked on the worker thread, not on the transient compute threads.
- File input needs the service stopped: a second copy of the models does not fit.

## Left on the device

- straylight-voice `listen/packaging/install.sh` files: `/usr/local/bin/straylight-listen` (ASR build), `/usr/local/share/straylight-listen/` with `Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf` and `silero-vad-v6.2-F32.gguf` (579 MB), the new `/etc/systemd/system/straylight-listen.service` (enabled, running), `/etc/straylight-listen.conf` = `--stats 600 --asr-gain 12 --record /var/lib/straylight-listen` (the `--record` kept from the wake-word stream).
- `/var/lib/straylight-listen/`: the user's four earlier recordings, restored after the test clips rotated them out (copies in `work/userrec/`, not for the repository).
- Speaker amp back at 145; test files in `/var/tmp` removed.

## For the image (`rootfs/scripts/`, not changed here)

1. Overlay: `usr/local/bin/straylight-listen` (built `--features asr`; needs glibc, `libgcc_s`, `libasound.so.2`), `usr/local/share/straylight-listen/{frontend.slt,hey-straylight.slt,Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf,silero-vad-v6.2-F32.gguf}` (models from `streams/asr/downloads/models/`, sums in straylight-voice `listen/asr/models.sha256`: `7441f767…cefb443a`, `0d871a80…eb1c88e6`), `etc/systemd/system/straylight-listen.service` and `etc/straylight-listen.conf` from straylight-voice `listen/packaging/`. +579 MB on root.
2. `systemctl enable straylight-listen.service` in the chroot.
3. No new packages.
4. Recommended: drop-ins `OOMScoreAdjust=-900` for `tsv-adbd.service`, `NetworkManager.service`, `systemd-networkd.service` (sshd is already -1000), so a global OOM can only pick the pipeline.
5. Checks: `systemd-analyze verify`, `ldd` under qemu for `libasound.so.2`, the model sums.

## For the ai& client

Implement `Responder::respond(&self, req: Request, send: &dyn Fn(Reply) -> bool)` (straylight-voice `listen/src/responder.rs`): it runs on its own thread when Thinking starts; `req` has the phrases (text and language each), the joined text and the main language. Send `Reply::Lang` (optional), `Reply::Text` pieces as they stream in (shown at once, appended), then `Reply::Done`, or `Reply::Failed` (Offline for 5 s). Stop when `send` returns false (cancel). Replace `responder::Echo` in `main.rs`, and give the unit network access (drop `PrivateNetwork=yes`, allow `AF_INET`/`AF_INET6`). Speech output will later replace the reading-pace `spoken_chars` with the synthesiser's progress.

## Scripts

| Script | What |
| --- | --- |
| `make-testset.py` | wake word + command test requests, 16 kHz and 48 kHz, `work/testset/refs.tsv` |
| `make-demo.py` | pads the synthesised "what's the weather tomorrow" demos into the test set |
| `device-file.sh TAG [GLOB] [options]` | file input through the pipeline on the device (service stopped meanwhile) |
| `device-acoustic.sh TAG [GLOB]` | clips through the speaker to the running service |
| `summarise.py LOG [--per-utt] [--only RE]` | timings, accuracy, capture timing, RSS |
