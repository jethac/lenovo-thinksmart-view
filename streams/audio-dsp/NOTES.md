# audio-dsp stream

QDSP6 audio recovery after xruns, the freedreno GMEM fix, and GPU faults against the Straylight screen. Starting point: three findings in justhalfbit's `thinksmart-ubuntu-image` (MIT; Ubuntu with the postmarketOS 6.19.5 kernel): the q6asm capture path surviving only one prepare per open, a Mesa GMEM patch, and a GPU-fault watchdog for a frozen kiosk.

## Status (2026-11-03)

- **Xrun recovery: the hazard does not reproduce on our 7.3 kernel.** 25 forced capture overruns recovered with `snd_pcm_recover` (prepare again), with no DSP errors, and the live listener recovered from one in place. Close-and-reopen works too (9 of 9, about 100 ms). Playback on `hw:0,0` never underruns at all. straylight-listen now reopens instead of re-preparing anyway, as insurance (branch `audio-dsp-recovery` in straylight-voice, commit `76e1e49`, not pushed). It was verified on the device in a temporary unit but **not deployed**. See [For the integrator](#for-the-integrator).
- **GMEM fix: ported to 26.2.6, it builds, and it fixes three hangs on the device. Not worth shipping now.** Nothing on the device renders through Mesa's GMEM path: the system has no Mesa, the screen uses Slint's software renderer, and straylight-gpu forces sysmem. Keep the patch for the day Mesa goes in system-wide.
- **GPU-fault freeze: no evidence on our device. No fix proposed.** 4,336 GPU recoveries in 31 boots, every one caused by a GPU test program. The screen ran through 2,871 of them without a restart and took touches afterwards. It never submits GPU work.

## 1. QDSP6 xrun recovery

### The claim, and what the 7.3 code does

justhalfbit (`xiaozhi/thinksmart-mic`): "The q6asm capture path on this device survives exactly one prepare per open: any second prepare (PortAudio opening the device, or arecord recovering from an xrun) fails with 'Buffer already allocated' and leaves the DSP broken, speaker included, until reboot." His PipeWire config also pins 48 kHz because a rate switch re-prepared the speaker PCM with the same error, and it disables PipeWire's ALSA source, which timed out in the DSP (`CMD 10bcd` = `ASM_STREAM_CMD_CLOSE`).

In `sound/soc/qcom/qdsp6/q6asm-dai.c` (7.3), `q6asm_dai_prepare` on a stream that already ran sends `CMD_CLOSE`, unmaps the DSP memory, `q6routing_stream_close`s, then maps again and reopens. The weak spot is in `q6asm.c`:

- `q6asm_unmap_memory_regions` frees the port's buffer list only if the unmap command succeeds. If the DSP times out (5 s) or errors, `port->buf` stays.
- `q6asm_map_memory_regions` then finds `port->buf` set, prints "Buffer already allocated", and **returns 0**. The prepare goes on to open the stream on a stale mapping.

So the second prepare is harmless as long as the DSP answers the close and unmap. Once one command fails (his PipeWire `CMD_CLOSE` timeout), every later prepare on the same open builds on the stale state. A **new open** allocates a new q6asm audio client (`q6asm_dai_open`) with empty ports, so nothing carries over.

Two more details, both from the same code:

- **Playback cannot underrun.** Buffers go to the DSP from `.ack`, only as far as the application has written, and the pointer callback returns one frame less than the DSP position. The ALSA state stays `RUNNING` through a stall; a recover/prepare then fails with `EBUSY` (`snd_pcm_pre_prepare` on a running stream).
- **Every open already prepares twice.** alsa-lib's `snd_pcm_hw_params` prepares, and straylight-listen prepared again. Before the stream starts, that second prepare runs the full close/unmap/map/open on the DSP, and it has worked on every start.

### Test

`xrun-test.c` opens a PCM the way straylight-listen does (48 kHz, S16_LE, 2 channels, 20 ms periods; capture buffer 160 ms, playback 80 ms; `hw_params` plus an explicit prepare). It runs for 1 s, then stops reading or writing for 0.2-2 s. It then recovers (`snd_pcm_recover`, as the listener's `try_recover`) or reopens, and checks that the next 0.5-1 s moves audio at real-time rate. The capture level shows real microphone signal. It is non-blocking with 1 s poll timeouts, so a stuck DSP would show as a stall. `XRUN_BLOCK=1` uses blocking reads with the read starting the stream, exactly as the listener does. Playback writes silence only. `session-xrun.sh` runs the tests in one locked session with the listener stopped (18-69 s per session) and logs dmesg after each.

| Test (session) | Result |
| --- | --- |
| capture, plain open (1, 3) | 48000 frames/s, -55 dBFS (mic floor with the listener's +24 dB) |
| capture, overrun then reopen (1: 1 cycle; 2: 8 cycles, idle 0.2-1.8 s) | 9/9 recovered, reopen 99 ms, level unchanged (the mixer route and gain stay set) |
| capture, overrun then `snd_pcm_recover`, non-blocking (1: 1; 2: 12 cycles) | 13/13 recovered, the buffered backlog then real time, level unchanged |
| capture, the same, blocking as in the listener (3: 12 cycles) | 12/12 recovered |
| playback, 0.2-1.4 s without writes (1, 2) | state stays `RUNNING`, no underrun; `snd_pcm_recover` and `snd_pcm_prepare` return `EBUSY`; writing again just works (5/5) |
| playback, reopen (1) | works, 125 ms |
| capture and playback, plain, after all the above (1, 2, 3) | both work |

No `q6asm`, `apr` or other audio messages in dmesg in any session. In the deployed listener, a 0.6 s `SIGSTOP` caused an overrun ("snd_pcm_readi failed with error 'Broken pipe (32)', recovering"). Capture went on at 48,960 frames/s, with no restart.

So on this kernel the recover path works, and the reported failure needs a DSP command to fail first. We have not seen one fail. His trigger was PipeWire's own source, which we do not run.

### The change (straylight-voice, branch `audio-dsp-recovery`)

Worktree `../straylight-voice-audio`, one commit on `main` (`e71bfea`):

- `listen/src/audio.rs`: an overrun or read error closes `hw:0,1` and opens it again with the same hardware parameters, instead of `try_recover`. If the reopen fails, the error ends the capture thread as before, and systemd restarts the service. The mic route and gain are not re-applied: they are card controls and stay set across PCM opens (the level after reopen was unchanged).
- `listen/src/tts/player.rs`: a write error closes `hw:0,0`, counts what the device held as heard (so the screen moves on), and lets the next period open a new stream. The old try_recover-then-prepare could not work here (`EBUSY`, see above).
- Both opens drop the explicit `prepare()` after `hw_params`, so each open sets up the DSP stream once.
- `listen/README.md`: a paragraph on xruns, 48 kHz and S16_LE.

Verified: cross-built with `--features asr,tts` (`0.1.0 (953ad5c)`, the same code before a README-only amend to `76e1e49`) and run in a transient unit with the service stopped (22 s). Three forced overruns (0.6 s `SIGSTOP`) each logged "reopening hw:0,1", and capture continued at 48,960 frames/s. The installed listener was then restarted. The playback change cannot be forced on this kernel (no underrun, and no other write error to provoke), so only its normal open path is covered, by the same `hw_params` + `sw_params` sequence `aplay` uses.

### justhalfbit's other findings, against our setup

- **Keep 48 kHz fixed.** Already the case: the listener and player open both PCMs at 48 kHz, S16_LE, 2 channels and never change it, and no PipeWire runs. A rate change would mean a new `hw_params` and prepare; with reopen it would mean a new open, which is the safe way should it ever be needed.
- **S24 output much quieter than S16.** Confirmed by the speaker stream: S24_LE through `hw:0,0` is about 48 dB quieter (`streams/speaker/NOTES.md`; 24-bit LSB-aligned samples read as Q31 in q6asm). The player writes S16_LE only.
- **PipeWire's ALSA source times out in the DSP.** Not applicable while the listener owns `hw:0,1` and nothing starts a user PipeWire (the listener README already warns about that).

## 2. freedreno GMEM fix

### The patch

`patches/0001-freedreno-gmem-no-fit-sysmem.patch`, his `mesa/freedreno-gmem-fix.patch` as a `git format-patch` on mesa-26.2.6. It applied with an offset only; the code it changes is the same in 26.2.6. It fixes two bugs in `src/gallium/drivers/freedreno/freedreno_gmem.c`:

1. `gmem_key_init`: the depth/stencil size per pixel is `layout.cpp * pfb->samples`, but `layout.cpp` already includes the resource's sample count (`fd5_layout.c`: `cpp *= nr_samples`). A 4x depth/stencil buffer counts as 16x.
2. `calc_nbins`: adds bins until the layout fits. Once bins are at the tile alignment (64x32 on a5xx), more bins cannot make them smaller, and the loop never ends. The patch marks the layout `no_fit`, and `fd_gmem_render_tiles` renders the batch in sysmem.

What fits on the A506: GMEM is 136 KiB (`a5xx_catalog.c`), the smallest bin is 64x32 = 2048 pixels, and on a5xx every buffer's base is aligned to 16 KiB (`gmem_page_align = 4`). So a framebuffer stops fitting at about 68 bytes per pixel, or at 9 attachments of any size.

### Build

`build-mesa-gmem.sh` reuses `streams/gpu-mesa16`'s clone, sysroot, venv and cross file. It builds in a worktree and build directory of its own (`gpu-mesa16/work/src-gmem`, `build-gmem`, staged as `/opt/mesa-gmem`, 30 MiB), so the gpu-mesa16 trees are untouched. It builds clean (release, same options as gpu-mesa16's stock build).

### Test on the device

`gmem-msaa-test.c` clears an 800x1280 (panel-size) framebuffer of N RGBA8 colour targets + DEPTH24_STENCIL8, at 1x or 4x, resolves it and reads back a pixel. It ran with `/opt/mesa-stock` (gpu-mesa16's unpatched 26.2.6) and with `/opt/mesa-gmem`, each in a 300 MiB, 12 s transient unit (session 7):

| Framebuffer | Bytes/pixel in the key (stock → patched) | Stock 26.2.6 | Patched |
| --- | --- | --- | --- |
| 1x, 1 RGBA8 + Z24S8 | 8 | renders, 48 ms | renders, 46 ms |
| 4x, 1 RGBA8 + Z24S8 | 80 → 32 | **hangs** (killed at 12 s) | renders in GMEM, 73 ms |
| 4x, 4 RGBA8 + Z24S8 | 128 → 80 | **hangs** | renders in sysmem, 163 ms |
| 1x, 8 RGBA8 + Z24S8 (9 buffers) | 36 | **hangs** | renders in sysmem, 159 ms |

All rendered pixels were correct, and there were no kernel messages (the hang is a CPU loop in the driver, not a GPU hang). On the laptop the noop drm-shim (`FD_GPU_ID=510 FD_MESA_GMEM=139264`) shows the same hang in `calc_nbins` → `layout_gmem`, with `nbins_x` grown past 10 million. 2x with one target fits even with the double count.

### Can the Straylight screen hit it?

No, not as it is:

- The device has no system Mesa (`pacman -Q mesa`: not installed). `/opt/mesa-*` are gpu-mesa16's private test builds, used through `LD_LIBRARY_PATH` only.
- straylight-voice is built with Slint `renderer-software` only (linuxkms backend, DRM dumb buffers, XRGB8888). It opens `/dev/dri/card0` for KMS and maps no GL library.
- straylight-gpu (Kokoro's decoder, off by default) sets `FD_MESA_DEBUG=sysmem` before `eglInitialize`, so it never uses GMEM.

If the screen moves to a GPU renderer (README, "Not done yet"), it still would not hit it with Slint's defaults. The linuxkms FemtoVG and Skia paths pick the EGL config with the fewest samples, so the window is single-sampled, and Slint's layers are single-sampled RGBA8 textures. That is 1-2 buffers at 4-8 bytes per pixel, which fits at any size. The hang needs 4x MSAA with depth/stencil or 9+ attachments. That is what a browser engine does (WebKit/Skia with MSAA, his case), not our UI.

**Verdict:** not worth shipping now; nothing would exercise it. Carry it if Mesa is ever installed system-wide (GPU UI, a browser, anything third-party), because then any app asking for 4x MSAA + depth hangs in a busy loop. Better still, send it upstream: per his notes, neither fix is in Mesa main.

## 3. GPU faults and the screen

His watchdog (`kiosk/gpu-watchdog.py`) follows the kernel log and restarts the kiosk browser 5 s after any `hangcheck recover|gpu fault|opcode error`. He saw a fault about 20 s after kiosk start on one boot in five, after which the browser showed its first frame until restarted.

Our journal (31 boots, 2026-10-19 to now, read-only):

- Faults in 3 boots only (4,336 recoveries, 4,227 `gpu fault` lines): -5 (2026-10-30 22:04-22:33), -4 (22:36-22:37), 0 (2026-11-01 08:00-10:xx, 12:59-14:09, 2026-11-02 09:xx, 2026-11-03 15:03). None in the first minutes after a boot, and no `opcode error` ever.
- Every recovery names an offending task, and all are GPU test programs: `gles-sgemm` (1465), `gles16` (1440), `sg-bench` (1404), `gles-fp16` (18), `deqp-gles31` (3), and the Radish driver tests `radish-ncnn`, `compute`, `resources` (6). Never `straylight-voice`, which submits no GPU work.
- The screen survived all of it. `straylight-voice` started 2026-11-01 07:44:30 and has had 0 restarts. Since then it went through 2,871 recoveries. It took touches (settings opened and closed, 2026-11-01 14:57, after 2,870 of them) and ran a full wake → reply at 18:17. The listener saw both through the screen's socket.

**Verdict:** no freeze to fix, so no change on the branch. Scanout of software-rendered dumb buffers does not depend on the GPU ring the recoveries reset. If the screen ever renders with the GPU, a watchdog like his would be the template, but it must only act on faults whose offending task is the screen. On this device, test programs fault the GPU thousands of times, and his version would restart the UI on each.

## Files

| What | Path |
| --- | --- |
| Xrun test program | `xrun-test.c` (build line in its header; binary in `build/`, git-ignored) |
| Locked xrun session | `session-xrun.sh OUTDIR [DIR:MODE[:CYCLES[:block]]...]` |
| GMEM patch (on mesa-26.2.6) | `patches/0001-freedreno-gmem-no-fit-sysmem.patch` |
| Mesa build | `build-mesa-gmem.sh` → `../gpu-mesa16/work/stage-gmem/opt/mesa-gmem` |
| GMEM test program | `gmem-msaa-test.c` |
| Session logs | `work/session-{1..5,7}/` (git-ignored; `session-6-bad` had a test bug, the depth/stencil buffer was not attached) |
| straylight-listen change | `jethac/straylight-voice` branch `audio-dsp-recovery`, worktree `../straylight-voice-audio` (local only) |

## Left on the device

Nothing. The test binaries (`/root/xrun-test`, `/root/sl-test`, `/root/gmem-msaa-test`) and `/opt/mesa-gmem` were removed. The transient units are gone. The installed straylight-listen (built 2026-11-01 09:48) is unchanged and running. The kernel was never changed (baseline `#5 … Oct 30 22:06:25`). Kernel log markers `audio-dsp: …` are in the current boot's dmesg.

## For the integrator

1. **straylight-listen**: branch `audio-dsp-recovery` (`76e1e49`) is ready to merge into straylight-voice `main`. It is insurance, not a fix for anything seen on 7.3. It is not deployed because a build from `main` also carries `ae32401`/`e71bfea` (the GPU decoder option and benchmark), which are not in the installed binary. It should go out with the next listener release, and other streams build from `main` and `asr-fast`. Re-check on the device after deploying: `kill -STOP` the listener for 0.6 s, then `kill -CONT`. The journal should show "reopening hw:0,1", and `/proc/asound/card0/pcm1c/sub0/status` should keep advancing.
2. **Mesa**: nothing to do now. If Mesa is ever installed system-wide, build it with `patches/0001` and offer the patch upstream (credit justhalfbit).
3. **Kernel (optional, upstream)**: the root cause sits in q6asm. `q6asm_map_memory_regions` returns success on "Buffer already allocated", and `q6asm_unmap_memory_regions` keeps the buffer list when the unmap fails. A patch could free the list regardless and fail the map on a stale one. Not written: nothing here reproduces the failure, so it could not be tested.
