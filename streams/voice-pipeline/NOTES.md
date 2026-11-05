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

## Conversation (2026-11-04)

straylight-voice branch `conversation` (worktree `straylight-voice-conversation`), commits `8a00855`..`da400b0` on top of `7da8c01`. Goal: `streams/multimodal/GOAL.md` section 1, and the ai& image check from section 4.

### Follow-up without the wake word

- After a spoken reply the listener listens again: the window opens 400 ms after the voice has stopped (`--follow-up-guard-ms`; "done" means played and the PCM closed, so the guard only covers the room ringing) and stays open 7 s (`--follow-up-ms`, 0 turns it off). There is no echo cancellation, so nothing is heard while the reply plays.
- Speech in the window is a new turn of the same conversation (Captions, Thinking, Speaking as usual). Silence for the whole window, a tap, or a closing phrase said on its own ends it: "thanks", "thank you", "that's all", "no thanks", "never mind", "bye", ありがとう(ございます), 以上です, 大丈夫です, 谢谢, 没有了, 不用了, 再见 and a few more, with fillers ("okay, ...") and "Straylight" allowed around them. "Thanks, and what about Tuesday?" still goes to the model. A closing phrase ends quietly, without a request.
- Guards against the tablet's own voice and the room: the window opens after the guard; a first phrase that is only the end of the reply is dropped; a wake phrase said again at the start is stripped; a phrase more than 12 dB quieter than the user's voice at the wake word (the loudest phrase of that turn, 90th percentile of its 20 ms block levels) is taken for someone else and ignored (`--follow-up-level-db`).
- The screen has a new `followup` state: the conversation, newest reply in white, a red bar draining over the window, "Say more, or tap to finish", and a New conversation button.

### Conversation policy (`listen/src/conversation.rs`)

- Each request carries the system prompt, a summary of older turns (if any), recent turns word for word, and the request.
- Recent turns are held to an estimated 1200 tokens (`--history-tokens`; a Latin character counts 1/4, any other character 1) and at most 12 turns (`--history-turns`). When a finished turn takes them over the budget, all but the last 2 (`--history-keep`) are folded into a summary of at most 80 words. The model writes it after the reply, on a thread of its own, so it never delays a reply. If that fails, those turns are dropped. Until it is done, a request sends what fits in twice the budget.
- Images: a turn can carry images (`Request.images`, `data:` URLs). They go with their own turn only; after the reply the model is asked for a two-sentence description, which takes the image's place in the history.
- The conversation is forgotten after 300 s without a request (`--history-idle-s`), when "new conversation" / "start over" / 新しい会話 / 重新开始 (and similar) is said after the wake word or in the window (acknowledged aloud, and the window opens again), or when New conversation is tapped. "New conversation, <question>" starts the new conversation with the question.
- Measured on the tablet (`straylight-listen --ask ... --history-tokens 300`, muse-spark-open): a summary of 3 turns took 786 ms (404 tokens in, 336 out, reasoning included); an image description took 544 ms (1178 in, 187 out). After the summary, a question about facts from the summarised turns and from the image was answered correctly. Replies' first text: 0.3-0.7 s (2.0 s for the first request).

### Screen protocol

`{"conversation":[{"request":[phrases],"reply":phrase},...]}` (alone or with any state), state `followup` with `window_ms`, event `{"event":"new_conversation"}`. straylight-voice README, "The socket protocol". Headless check: `straylight-voice --screenshot DIR --script tools/conversation-screens.txt`.

### Device test (acoustic, 2026-11-04)

The demo requests and synthesised follow-ups (Kokoro `af_sky` / `jf_nezumi`, played through the tablet's speaker at the user's volume 183), the installed service listening:

| Step | Result |
| --- | --- |
| "Hey Straylight, what's the weather tomorrow?", then "What about the day after?" in the window | answered in context; window opened 402 ms after the voice stopped |
| then silence | window closed after 7.0 s (`follow_up_silence`) |
| Japanese request, then "Thank you." | `closing`, no request sent |
| request, then "New conversation." | acknowledged, window reopened; then "じゃあ明後日は" answered as a fresh conversation |

Window opening: 400-420 ms after the end of the voice in all 8 windows. Follow-up phrases came in at -46 to -49 dBFS against a voice level of -49 to -50 dBFS. In the first run, before the level check, people talking in the room were picked up twice: "New conversation." gained a background phrase and missed the match, and one window ran to the 15 s cap on background chatter and was sent as a turn. The level check was added for this. Background levels were not measured in the second run because the room was quiet, so the 12 dB margin is a first guess. **A live voice test by the user is still needed**, to check the margin against real voices and to check the closing phrases as people actually say them.

### ai& images (meta/muse-spark-open)

- `/v1/models` lists `chat, reasoning, video, vision, tool_calling`. The docs (docs.aiand.com, Chat Completions and Vision) take OpenAI-style `content` arrays with `image_url` (public https URL, `data:` URL, or a Files API `file_id`) and `video_url`. Types: PNG, JPEG, WebP, GIF, up to 100 MiB per file. No inline request size limit is documented.
- Image tokens (`usage.prompt_tokens_details.image_tokens`), synthetic test card, JPEG q85:

  | Size | Image tokens |
  | --- | --- |
  | 320x240 | 108 |
  | 640x480 | 391 |
  | 1024x768 | 972 |
  | 1304x980 | 1645 |
  | 1600x1200 | 2451 |
  | 2608x1960 | 4015 (scaled down by the server) |

  That is about one token per 28x28 pixels (784 px²), with a cap near 4000. `detail: low` and `high` cost the same (972 tokens at 1024x768), so `detail` is ignored. The same image sent again is served from the prompt cache (1024 cached tokens), at the cached price ($0.15 against $1.25 per 1M). Two images cost the sum of the two. All sizes read "TEST CARD 42" correctly. First text in 0.4-0.8 s.
- Video: an inline `data:video/mp4;base64` `video_url` is accepted (the docs only describe URLs and file_ids). The model described the motion in a test clip correctly. Video is about 260 tokens per second at 640x480 and about 117 per second at 320x240, independent of the source frame rate (2 s at 6 fps and at 30 fps both cost 521 tokens, so the server samples its own frames). For comparison, six separate 640x480 images cost 2346 tokens. Video is the cheaper way to send motion.
- straylight-aiand `chat` now takes user content as parts: `text`, `image_url` and `video_url`, each as a `data:` URL that is checked (type, base64, leading bytes). Limits: 8 per request, 1.5 MiB each, 4 MiB together, lines up to 6 MiB (the daemon runs in 64 MB). Remote URLs are refused. A request with images to a model whose catalog lacks `vision` (or `video`) is refused as `no_vision`. The done line carries `usage`. `straylight-aiand ask --image F [--detail D] [--video F] TEXT` is there for probing.

### Left on the device

- (2026-11-05: `straylight-listen` and `straylight-voice` replaced by the `photo` builds, see "Photo" below.) `/usr/local/bin/straylight-aiand`, `straylight-listen` (asr,tts) and `straylight-voice` from branch `conversation` (listener at `777783d`, screen at `6f4a20d`, aiand at `8a00855`), all three services enabled and active when work stopped. Backups: `/usr/local/bin/{straylight-aiand,straylight-listen,straylight-voice}.pre-conversation`. To roll back, install the backups and restart the three services.
- `/etc/straylight-listen.conf` is unchanged; the new options are at their defaults.
- Test files still in `/var/tmp/straylight-cards/` (synthetic test cards and clips) and `/var/tmp/fu/` (demo and synthesised clips, test script). They hold no captures; delete them when the device is back.
- Speaker volume is unchanged (183, as saved in `audio.json`).

### Open

- The user's live voice test of the follow-up window and the level margin.
- The screen and listener builds for the image (`rootfs/scripts/`): same files as before, no new packages.
- Whether to keep `meta/muse-spark-open` for voice: it reasons (`low` is its lowest effort), and its first text arrived in 0.3-2.0 s in these tests.

## Photo (2026-11-04)

straylight-voice branch `photo` (worktree `straylight-voice-photo`), on top of `conversation` (`da400b0`): `7bdda18` (screen), `8cf0738` (listener), `4c3f95a`, `578a62e`, `7b6e2f6`. Goal: `streams/multimodal/GOAL.md` section 4, "Photo".

### What it does

- **Button** at the top right: left of the settings button on Idle, in its place on Listening, Captions and Followup (their headers keep the corner free). A tap starts a countdown (`photo_countdown` in `/etc/straylight-screen.conf`, default 3 s, 0 to 10).
- **Camera on**: the camera is opened when the countdown starts, so exposure and white balance settle during it, and closed as soon as the frame is taken. For exactly that time a red frame runs round the whole screen and the card says "Camera on". A tap anywhere during the countdown cancels it and closes the camera (within about 200 ms); so does closing the lens cover.
- **Lens cover** closed when the button is pressed: the camera is not opened, and the screen says "The lens cover is closed. Slide it open to take a photo." for 3 s.
- **Preview**: the photo is shown large for 2.5 s with Discard and Keep, then as a thumbnail in the button's place (red border once it has gone with a question); a tap on the thumbnail shows it large again.
- **Which question**: the listener attaches the photo to the request being made, or to the next one. A request that ends while the countdown runs waits for the photo. A photo taken from Idle opens the follow-up window for the question ("Ask about the photo"); in an open window the window starts over.
- **Voice**: "take a photo" at the start of a request starts the countdown from the listener (also "take a picture", "snap a photo", "can you take a photo", 写真撮って, 写真を撮って(ください), 拍张照, 拍照, 帮我拍张照, and a few close variants). It must open the request and be followed by nothing, a sentence break, or "and ..."; "How do I take a photo?", "Take a photo of the sunset tips", 拍照的时候要注意什么 are ordinary questions. What follows is the question; "take a photo" alone opens the window once the photo is in. If the photo fails while a request waits, a spoken line says why ("The lens cover is closed, so I can't take a photo." / "I couldn't take the photo.", in the request's language) instead of a reply without it.
- **Sent at the model's size**: the full readout binned 2x2 (980x1304, portrait) is scaled to `photo_size` on the long side (default 640: 480x640, area average) and JPEG encoded at quality 85. Only the listener's connection receives that copy (`photo_data`); other clients get the phase events without data.
- **Nothing kept**: the photo exists only after the button or the phrase. It is dropped when the turn that carried it ends (reply, stop, failure: the listener sends `{"photo":"clear"}`), when discarded, when a new one replaces it, after 120 s unused (`photo_keep`), or when the listener disconnects. In the listener the request is dropped after its turn and the conversation keeps the image only until the model has described it (as before). The screen overwrites its copies before freeing them; nothing is written to disk by either program.

Code: straylight-voice `src/photo.rs`, `src/camera.rs`, `camera/photo.c`, `ui/photo.slint`; `tsvcam.c`, `tsvcam.h`, `tsvsel.h` copied unchanged from `streams/camera/tsvcam/` into `camera/` (hashes in `camera/SOURCE`); listener `listen/src/main.rs` (`WaitPhoto`, `PhotoSlot`), `conversation::photo_request`. The screen now links `libturbojpeg.so.0` (libjpeg-turbo, already on the tablet and in the image); the sysroot scripts fetch it.

### Tests

- Unit tests: scaling (`fit`, area-average `downscale`), base64, PPM, countdown, config keys, the photo phrases (14 that must match, 8 that must not), the new socket events; a headless test of the whole screen flow on a virtual clock with a socket pair for the listener (countdown, `photo_data` only to the listener role, preview then thumbnail, attached photos do not expire, clear, a tap cancels, expiry, cover closed, listener gone). straylight-voice 34 tests, straylight-listen 25, all passing.
- End to end on the laptop (`tools/photo-e2e.sh`: the screen off-screen with `--photo-source` test card, the listener on synthesised WAVs at real-time pace with the ASR, `--no-tts`, echo responder): "Hey Straylight, take a photo. What does the card say?" (photo taken, sent with "What does the card say?", cleared after the turn); "Take a photo." then the question in the window it opened; the button pressed in Idle then the question in the window; 写真を撮って。(photo, window). The `--listen` control client saw the phase events and never the image data.

### Size for the model

`tools/photo-measure.sh` on the tablet (2026-11-05): five synthetic scenes (no captures), each through the screen's own scaling and encoding at five sizes, then to ai& with its question through the listener's request path, two rounds each. Image tokens are from `usage.prompt_tokens_details.image_tokens`.

| `photo_size` | Sent | JPEG q85 | Image tokens | Chart rows read right (of 7, 64 to 12 px tall in the 980 px frame) | Receipt (total, eggs) | Shapes, clock, label (8 tablets, 09/2028) |
| --- | --- | --- | --- | --- | --- | --- |
| 320 | 240x320 | 6-9 KB | 108 | 4 (rows from 22 px "too small to read") | total right, eggs wrong both rounds (4.05, 4.00) | all right |
| 480 | 360x480 | 13-18 KB | 221 | 4 (all 7 attempted; YQ66U, R5LCZ, T2P9N) | right | all right |
| 640 | 480x640 | 26-30 KB | 391 | 7 | right | all right |
| 960 | 722x960 | 72-77 KB | 910 | 7 | right | all right |
| 1304 | 980x1304, unscaled | 187-208 KB | 1645 | 7 | right | all right |

Scale and encode on the tablet: 90-240 ms and 3-25 ms (scale includes the screen's 480x640 preview; at 640 it is the same image).

**Default: 640 (480x640), 391 image tokens**: the smallest size that got every answer right; 960 costs 2.3 times as much for nothing more on these scenes, 480 starts misreading 16 px print. Answers came 0.35-1.5 s after the request.

9 of the 50 requests (spread over all sizes) failed with `server: Unexpected answer from api.aiand.com: an empty reply` and one reply stopped after two words ("I can make out K7"); neither depends on the image size. The listener speaks "ai& couldn't answer that. Please try again." for these. In the first, broken run (no images attached) 4 of 25 failed the same way, so it is not the images either.

### Device (2026-11-05, baseline #10, each session under the lock with the boot ID checked before and after)

1. Size measurement above (boot `db667998`, unchanged through it).
2. **Deployed** `straylight-voice` (`578a62e`, sha256 `f37cb9f9…`) and `straylight-listen` (`7b6e2f6`, asr,tts, `b6ae94af…`) to `/usr/local/bin`; backups `straylight-voice.pre-photo` and `straylight-listen.pre-photo` (the `conversation` builds). Restart: both active after 3 s, recogniser ready after 8 s, voices after 19 s. `findmnt /boot` checked first. Boot `e4a0bae4`, unchanged through it.
3. Live button test, real camera, nothing sent to ai&, nothing played: `{"photo":"take"}` on the panel's socket; red frame and "Camera on" with the countdown on the panel; capture 3.7 s from the press (3 s countdown, 100 ms exposure at gain 1.13 in a 1 lx room), scale 123 ms, encode 19 ms, 28 KB; `photo_data` reached the listener, which opened the window ("Ask about the photo"), closed it after 7 s of silence; the thumbnail stayed; `discard` dropped it on both sides. Panel grabs on the Shared partition (`lenovo-8-captures/photo/`), deleted on the tablet. Same boot throughout. (The tablet rebooted after this session released the lock: the old boot ends with an orderly journal sync, not a wedge.)
4. Test card through ai&, no sound (`--no-tts`, file input; the listener service stopped for 142 s): "Hey Straylight, take a photo. What does the card say?" -> countdown, card attached, "The card says TEST CARD 42 ..." (727 prompt tokens, 391 for the image), photo cleared after the turn; button pressed in Idle, then "What colors are the circles?" in the window it opened -> answered with the card, cleared. Services active afterwards; boot `1ec3a7ab` unchanged through it.

Seen on the grabs: the room in the preview looks turned 90 degrees. The camera notes say the 270 degree correction gives upright frames for the tablet standing in portrait; this needs a look with the tablet's actual stand.

### Left on the device

- `/usr/local/bin/straylight-voice` and `straylight-listen` from `photo` (above), backups `*.pre-photo`. To roll back: install the backups, restart both services. `straylight-aiand` and `/etc/straylight-screen.conf` unchanged (photo keys at their defaults).
- `/var/tmp/photo-test/` (55 MB): test binaries, the synthetic scenes, their scaled JPEGs and request logs, the test card, synthesised test WAVs. No captures. Remove with `rm -rf /var/tmp/photo-test`.
- The 7 s follow-up window of the live test was recorded by the listener's existing `--record` (`/var/lib/straylight-listen/utt-1793845170.wav`, room sound only); it rotates out with the others.

### Open

- The preview's orientation (above).
- The empty replies from ai& (9 of 50).
- The button's place and look, the 3 s countdown, the 2.5 s preview and the 120 s expiry are first choices; a look on the panel by the user.
- Whether a photo taken from Idle should open the listening window (it does now) or wait for the wake word.
- Whether "take a photo" said alone should also be acknowledged aloud (it is not: the countdown on screen is the acknowledgement).
- The image build: the same two files as before from `photo`; `libjpeg-turbo` is already in the image.
