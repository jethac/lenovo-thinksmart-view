# Video codec (Venus) stream — notes

Venus on the APQ8053 (`venus@1d00000`, `qcom,msm8953-venus`, HFI 3xx), mainline `venus_core`/`venus_dec`/`venus_enc` on Linux 7.3. Goal (`streams/multimodal/GOAL.md` §3): enabled on 7.3, decode and encode verified with frame counts, the B-frame limit explained, and its cost measured against the CPU.

## Status (2026-11-04, 16:10)

`0701` and the camera's `0404` are in the baseline (`kernel/patches`, 22 patches). **`0702`-`0704` are tested on the device and pass** (sessions 6 and 7, see "Verification of the fixes"):

| Item | State with `0702`-`0704` |
| --- | --- |
| H.264 and HEVC decode, with and without B-frames | 300/300 frames bit-identical to the software decoder for all six clips (H.264 Baseline, High, High bf 3, Main 720p bf 1; HEVC, HEVC bframes 4), clean end of stream; 1080p at 5.2-5.6x real time, about 0.27 s CPU per 10 s |
| Decode after encoder use, no module reload | bit-exact (300/300) |
| H.264 encode | every size tried: 640x480, 1280x720, 1920x1080, 490x652, 980x1304, 1304x980, streams of exactly the requested size |
| Camera frames → Venus H.264 | 60 `tsvcam` frames at 490x652 (1.0 s) and 980x1304 (2.0 s), decoded pictures correct |
| ffmpeg `h264_v4l2m2m` encoder | still broken on the ffmpeg side (segfaults at 1280x720/1920x1080/490x652, no SPS/PPS in its MP4 output); the kernel path is proven with `v4l2-ctl`. Not needed by the app, which should drive the encoder directly. |

Before the fixes:

| Item | State before the fixes |
| --- | --- |
| `0701` enables `&venus` with the board's firmware | builds clean on the baseline; probes, firmware loads on first open |
| H.264 and HEVC decode (no B-frames), 1080p | **works, bit-exact**: 300/300 frames identical to ffmpeg's software decoder, 5.4-5.6x real time, 0.26 s CPU per 10 s of video |
| Decode with B-frames | **fails** (hang at end of stream or lost frames); firmware decodes every picture, the loss is in the driver's output-buffer bookkeeping (see "B-frames") |
| Encode | **works only at 640x480** (H.264 High, HEVC Main, VP8 from `v4l2-ctl`); every other size tried never consumes an input buffer; ffmpeg's encoder fails even at 640x480 |
| H.264 encode from camera frames | **not achieved on Venus**; done on the CPU with libx264 instead (0.16 core for 490x652 at 6 fps) |
| Kernel config | nothing needed: `CONFIG_VIDEO_QCOM_VENUS=m` is already in the baseline |

## Files

- `kernel/patches-wip/video-codec/0701-arm64-dts-qcom-cd-18781y-enable-venus.patch`: `&venus { firmware-name = "qcom/msm8953/lenovo/cd-18781y/venus.mdt"; status = "okay"; }`. The `venus.mdt`/`.b00`-`.b04` blobs from the device's modem partition are already installed in the image at that path (with the ADSP and zap firmware); nothing goes in the repository.
- `device-test.sh`: on-device tests (`probe`, `decode`, `cpudecode`, `verify`, `order`, `bframes`, `traced`, `encv`, `ffdec`, `ffenc`, `encode-v4l2`, `encode-probe`, `encode-sweep`, `encode-synth`, `encode-camera`, `encode-camera-venus`, `encode-camera-x264`, `reload`). Every run is under `systemd-run -p MemoryMax=300M` with a time limit.
- `build-ffmpeg.sh`: cross-builds a small ffmpeg 8.1.3 (tag `n8.1.3`, commit `1041abdc962f`, cloned from `git@github.com:FFmpeg/FFmpeg.git`; ffmpeg.org reset the connection) with V4L2 M2M, the native H.264/HEVC decoders, libx264 (Arch Linux ARM `x264` 0.165.r3222 package, SHA-256 `ef95679c…0f70`) and file/pipe I/O, into `work/ffmpeg/` (6 MB, no dependencies beyond glibc and libx264).
- `kernel/patches-wip/video-codec/0702`-`0704`: the driver fixes (see "Root causes and fixes").
- `ffmpeg-v4l2-keep-pending-packet.patch`: ffmpeg fix, keeps a packet the decoder could not queue yet and waits for the source change instead of dropping it.
- `ffmpeg-decode-order-test.patch`: test hook in ffmpeg's V4L2 decoder; `TSV_V4L2_DECODE_ORDER=1` sets `V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE`=1 and `..._DISPLAY_DELAY`=0 (Venus `HFI_OUTPUT_ORDER_DECODE`). Applied by `build-ffmpeg.sh`.
- `venus-enc-streamoff-after-stop.c`: reproducer for the encoder hang (see the driver bug section; not to be run casually).
- `venus-trace-bufs-debug.patch`: debug only, not for acceptance. Adds a `trace` parameter (default off) to `venus_core` that logs every buffer queued to and returned by the firmware (lookup misses marked), reference park/release/resend, release-reference events, the encoder session geometry, and prints the firmware's own debug messages (level from `/sys/kernel/debug/venus/fw_level`).
- Test media (`work/media/`, not in git): 10 s testsrc2 clips made on the laptop with libx264/libx265: H.264 1080p Constrained Baseline, High without B-frames, High with `-bf 3` (has_b_frames 2), 720p Main `-bf 1`; HEVC 1080p `bframes=0` and `bframes=4`; 30 raw NV12 1080p frames for encoding.
- Session scripts and logs: `work/session{1,2,3,4}.{sh,log}`, pulled outputs in `work/s{1..4}-out/`.

## Device sessions (2026-11-04)

Four locked sessions, each: `kernel/deploy-to-device.sh --reboot build-video-codec` (baseline + `0404` + `0701`; session 4 also with the trace patch, `build-video-codec-trace`), tests, then `kernel/deploy-to-device.sh --reboot` back to `build-7.3`. Every boot came back within 2 minutes with `straylight-listen` and `straylight-voice` active; the device was on the baseline after each session (boot ID and release checked). The lock was held from deploy to restore.

### Probe

```
platform 1d00000.venus: Adding to iommu group 2
video6: qcom-venus-decoder    video7: qcom-venus-encoder
decoder OUTPUT: H264 VP80 VP90 HEVC VC1G VC1L MPG4 MPG2 H263 XVID, 16x16 - 3808x3808
decoder CAPTURE: NV12, Q08C (compressed)
encoder OUTPUT: NV12    encoder CAPTURE: H264 VP80 HEVC MPG4 H263
```

The node numbers swap after reloading the modules (the encoder can come up as `video6`); find them by name (`/sys/class/video4linux/*/name`).

### Decode

1080p30, 300 frames, `-f null` (hardware, after `rmmod`/`modprobe` of the Venus modules) and ffmpeg's own decoders on the 8 A53 cores:

| Clip | Venus: time / speed | Venus: CPU | CPU decode: time / speed | CPU decode: CPU |
| --- | --- | --- | --- | --- |
| H.264 Constrained Baseline | 1.80 s / 5.6x | 0.26 s | 1.44 s / 7.0x | 9.5 s |
| H.264 High, no B | 1.86 s / 5.4x | 0.29 s | — | — |
| H.264 High, B (bf 3) | fails | | 2.00 s / 5.0x | 13.3 s |
| HEVC Main, no B | 1.86 s / 5.4x | 0.27 s | 7.72 s / 1.3x | 17.1 s |
| HEVC Main, B (4) | fails | | 4.36 s / 2.3x | 17.1 s |

What Venus saves: playing 1080p30 H.264 in real time costs about 0.95 of a core on the CPU and 0.026 on Venus (about 36x less); HEVC about 1.7 cores against 0.027 (about 60x). ffmpeg's resident memory is about 100 MiB either way (Venus: twenty 3 MiB capture buffers).

**Correctness** (`device-test.sh verify`, per-frame MD5 of NV12 against ffmpeg's software decoder): H.264 Baseline, H.264 High without B and HEVC without B gave **300/300 frames, all bit-identical and in the same order**, no decode errors, each in a fresh firmware session.

**Session state matters.** In the first session (no module reload between runs) the same clips gave 298, 298 and 287 frames with three "driver decode error" frames each; after encoder attempts in the same boot, a decode (after a module reload) gave 288 frames of which only 66 matched. Reload the Venus modules before a decode that must be exact, and do not mix encoder use and decode in one boot without checking.

### B-frames

*Superseded by "Root causes and fixes" below: the trace there shows the reference-buffer explanation in this section was wrong; the lost EOS and ffmpeg's dropped packets explain the failures.*

Reproduced: H.264 Main `-bf 1` (720p), High `-bf 3` (1080p) and HEVC `bframes=4` all fail through `h264_v4l2m2m`/`hevc_v4l2m2m`. The failure is not a stall at frame 0 as on the 6.19.5 port; it varies by run: a hang at end of stream after most frames (HEVC: 292 of 300 delivered, then no more; H.264 bf 3: 255; 720p bf 1: 242), or a run that ends normally with frames missing (720p bf 1: 274 of 300; H.264 bf 3: 235 of 300 with two "driver decode error" frames). (Frame counts are ffmpeg's progress counter; the `framemd5` files of killed runs are empty because ffmpeg is killed before it flushes them.)

The trace (the traced runs, debug patch) shows the firmware doing its part:

- HEVC `bframes=4`, display order: the firmware consumed **all 300 input buffers** and returned **every picture in display order through the last one** (timestamps up to 9.966 s = frame 299), then the `V4L2_BUF_FLAG_LAST` / `HFI_BUFFERFLAG_EOS` buffer. Of the 320 output completions, 250 carry `HFI_BUFFERFLAG_READONLY` (0x200: the firmware keeps the picture as a reference); B-pictures arrive flagged `V4L2_BUF_FLAG_BFRAME`. ffmpeg nevertheless received only 292 frames and then waited for end of stream that never reached it.
- The LAST buffer came back on **tag 0, the same buffer the firmware had returned two frames earlier as a READONLY reference**. `vdec_buf_done()` looks the tag up on the vb2 queue (`venus_helper_find_buf()`); a buffer that is not queued at that moment (still held as a reference by the driver or dequeued by the client) is not found, and the completion goes to `venus_helper_change_dpb_owner()` and is dropped. Dropped completions are the missing frames, and a dropped LAST buffer is the end-of-stream hang.
- Decode order (`TSV_V4L2_DECODE_ORDER=1`): the firmware again consumed all 300 inputs and returned 300 pictures (203 B-pictures with data) and LAST; ffmpeg kept only the I and P pictures (2 + 95 for HEVC, 2 + 135 for H.264 bf 3), every one bit-identical to the software decoder. ffmpeg drops the B-pictures there because their timestamps go backwards, so this mode only shows that the I/P pictures are right; it is no workaround.

**Conclusion: driver, not firmware.** This firmware decodes B-frame streams and emits every frame and the EOS marker in order. Frames are lost where the driver matches firmware completions to V4L2 buffers in dynamic-buffer mode: with B-frames the firmware holds more pictures as references (READONLY) and returns buffers whose vb2 counterpart is not on the queue, and those completions are silently dropped. No-B streams survive because a READONLY buffer is released before it is returned again. Next step for a fix: log the `!vbuf` path and `HFI_EVENT_RELEASE_BUFFER_REFERENCE` events with the trace patch, and compare with how the downstream `msm_vidc` driver handles reference-held output buffers on HFI 3xx; a cheap check meanwhile is ffmpeg's `-num_capture_buffers` (default 20) raised, to see whether starvation shifts the loss.

Practical rule until then: Venus decodes streams without B-frames (cameras, `-bf 0`, `-tune zerolatency`); anything else goes to the CPU decoder.

### Encode

- `v4l2-ctl` M2M encode, 30 NV12 frames: **640x480 works** in H.264 (High, 30 frames, valid stream), HEVC (Main, 30 frames) and VP8 (525 KB raw VP8 frames, not checked further). The trace shows each input buffer consumed and an output returned (first one a keyframe, 16.9 KB).
- **Every other size fails the same way:** 480x640, 1280x720 (the driver's default size), 1920x1080, 1920x1088, 976x1296, 490x652, 496x656. Formats and buffers are accepted, both queues stream on, and then the firmware never takes an input buffer (trace: 0 inputs done; 4 empty outputs returned at stream off). No kernel error, no firmware system error. 480x640 failing while 640x480 works rules out a pixel-count or bandwidth limit; it looks like the session's frame size or buffer layout not reaching the firmware correctly except for one geometry. Not resolved.
- ffmpeg `h264_v4l2m2m` produced no frames at any size, 640x480 included (empty output; at 1080p it waited 2 minutes at frame 0).
- So **H.264 encode from camera frames does not work on Venus yet**: `tsvcam stream --nv12 --align 16` piped into `h264_v4l2m2m` at 480x640 and 976x1296 ended with "Connection timed out" after three frames.

CPU encoding for comparison (`-threads 4` unless noted):

| Source | Encoder | Result | CPU |
| --- | --- | --- | --- |
| Camera 490x652, 6 fps, 60 frames (`tsvcam --nv12`) | libx264 ultrafast, zerolatency, 1 thread, 1 Mb/s | 60 frames, 1.27 MB per 10 s | 1.6 s per 10 s = 0.16 core (+0.2 core for `tsvcam`) |
| 1080p30 testsrc, 300 frames | libx264 ultrafast, 8 Mb/s | 300 frames, 2.1x real time | 22.7 s per 10 s video = 2.3 cores at real time |
| 1080p30 testsrc, 300 frames | libx264 veryfast, 8 Mb/s | 300 frames, 0.49x real time | 60.4 s (cannot keep up), 290 MiB RSS |

For the assistant's 6 fps camera stream the CPU encoder is cheap enough (0.16 core). Venus would matter for 720p/1080p video, which needs the encoder fixed first.

## Root causes and fixes (2026-11-04)

Session 5 ran the traced kernel (baseline + `venus-trace-bufs-debug.patch`) with the firmware's own debug output on (`/sys/kernel/debug/venus/fw_level` 0x1e/0x1f; the firmware reports `VIDEO.VE.4.2-00078`, built Nov 18 2019). Logs: `work/s5-out/*.klog`.

### Encoder only at 640x480: input buffers 128 bytes short (`0702`)

The firmware refuses every input buffer at the other sizes:

```
venc_EmptyThisBuffer(7152): ETB offset size 0[--expected is less than -128]or allocLen 1413120 [expected is greater than 1413248]
```

It wants the buffer to extend at least 128 bytes past the NV12 planes. `get_framesize_raw_nv12()` returns luma + chroma rounded up to 4 KiB; that is exact for 1280x736, 1920x1088 and 512x640 (no slack, refused) and leaves 2 KiB for 640x480 (accepted), which matches every size tried in sessions 2-4. ffmpeg's encoder failed for the same reason (in a fresh session ffmpeg at 640x480 encoded 60 frames). `kernel/patches-wip/video-codec/0702-media-venus-helpers-leave-slack-after-the-NV12-chroma-plane.patch` adds 4 KiB after the chroma plane.

### Encoder codes the padded size (`0704`)

The same log shows the padding being encoded: `FRAME_SIZE: nWidth=1280, nHeight=736`, `frameHeightCoded: 736` for a 1280x720 request. `venc_try_fmt_common()` rounds the format to 128x32 (the raw buffer layout) and `venc_s_fmt()` also used that as the frame size and default crop. `0704-media-venus-venc-encode-the-requested-frame-size-by-default.patch` keeps the rounded format for the layout and encodes the requested (even) size; `VIDIOC_S_SELECTION` still narrows it. Without it a 490x652 camera frame would be coded as 512x672.

### B-frames: the EOS arrives on a buffer the driver has already returned (`0703`)

Traced HEVC (`bframes=4`, 1080p, 300 frames): the firmware consumes all 300 inputs and returns all 300 pictures in display order, then signals end of stream on the tag of the buffer it has just returned:

```
dec qbuf out idx 0 addr 0xdb400000 ...
dec done out tag 0 bytes 3133440 flags 0x10 hfi 0x0 ts 9966667
dec done out tag 0 bytes 0 flags 0x100000 hfi 0x1 ts 0 MISS
```

Buffer 0 is no longer on the m2m queue, `venus_helper_find_buf()` fails and `vdec_buf_done()` drops the message, so the client never gets `V4L2_BUF_FLAG_LAST` and its drain hangs. Release-reference events carry the right tags (they match the buffers' addresses), so reference handling is not the problem; the earlier "driver drops reference-held buffers" reading was wrong. `0703-media-venus-vdec-deliver-an-EOS-the-firmware-signals-on-a-returned-buffer.patch`: on such an EOS, flush the firmware's output queue (non-blocking, as `vdec_event_change()` already does from the message thread) and mark the first empty capture buffer that comes back as LAST; if none comes back, the client's next capture buffer is returned as LAST.

### Missing frames and "corruption after the encoder": ffmpeg drops packets (ffmpeg patch)

H.264 `-bf 3` delivered 298/300 frames, all bit-exact, with frames 14 and 16 missing; the post-encoder Baseline decode delivered 293 with everything from frame 16 wrong. In both, the driver never received some packets (traced `qbuf in`: 298 and 293; missing packets 16-17, and 16-19 plus 21-23). ffmpeg's `v4l2_receive_frame()` holds a packet when all 16 OUTPUT buffers are queued, then calls `v4l2_try_start()`, which fails while `VIDIOC_G_FMT(CAPTURE)` is refused before the source change ("VIDIOC_G_FMT ioctl", repeated 17-22 times); the error path frees the held packet. How many packets are lost depends on how long the firmware takes to raise the source change, not on the encoder; in a P-only stream one lost packet corrupts everything up to the next IDR, which is what was seen after encoder runs. The driver's `-EINVAL` for that `G_FMT` is allowed by the stateful decoder interface, so the fix belongs in ffmpeg: `ffmpeg-v4l2-keep-pending-packet.patch` keeps the packet and waits (bounded, about 5 s) for the source change or a free OUTPUT buffer before going on (applied by `build-ffmpeg.sh`; upstreaming is optional, see below). The earlier counts of 298, 287 and 288 frames were this too. The decode-order experiment's missing B-frames were a separate artefact (ffmpeg drops frames whose timestamps go backwards).

### Verification of the fixes

Kernel `build-video-codec-fix` (baseline + `0702`-`0704` + the debug patch, trace off). `/boot` checked mounted on every boot.

- Session 6 (15:50): the decodes of H.264 bf 3 and HEVC bframes 4 gave 300/300 bit-exact frames with a clean end of stream (the first fix working); `v4l2-ctl` encodes at all six sizes gave valid streams of the requested size; a decoded 490x652 frame matches its source exactly in geometry and colour. The first version of the ffmpeg fix (returning `EAGAIN`) made ffmpeg abort ("A decoder returned an unexpected error code"), so some decodes failed; rewritten to wait for the source change instead.
- Session 7 (16:03): with the corrected ffmpeg, all four decode clips verified 300/300 bit-exact including H.264 Main bf 1; B-frame decode timing 1.99 s (H.264 1080p), 1.92 s (HEVC 1080p), 1.04 s (720p), 0.18-0.27 s CPU; camera to Venus via `v4l2-ctl` at 490x652 and 980x1304 (60 frames each, 115 KB and 256 KB at the encoder's default rate, pictures correct); decodes after the encodes without a module reload bit-exact. ffmpeg's V4L2 encoder still segfaults (ffmpeg side). Camera encodes are on the Shared partition, not in the repository.

### Earlier session plan

`work/session6.sh`, one boot of `kernel/build-video-codec-fix` (baseline + `0702`-`0704` + the debug trace, off by default) under the lock:
- per-frame verification against the software decoder for all six clips, including the three B-frame clips, with a clean EOS;
- a traced HEVC B-frame run to confirm the EOS path;
- the encoder at 640x480, 1280x720, 1920x1080, 490x652, 980x1304 and 1304x980, with the stream dimensions checked, plus ffmpeg encodes;
- 1080p30 encode cost against libx264;
- `tsvcam` frames at 490x652 and 980x1304 into Venus H.264;
- decodes after encodes, without a module reload.

### Session hygiene (carried over and confirmed)

- Reload `venus_dec venus_enc venus_core` between unrelated runs; device nodes may swap. (The decode losses blamed on session state were ffmpeg dropping packets, see above; a reload only changed the timing.)
- Kill hung clients with `timeout -k`; a B-frame hang ends cleanly on SIGKILL and the next module reload recovers (no D-state Venus tasks seen; the one D-state kworker in the logs was the display's `dpu_encoder_phys_vid_wait_for_*`, not Venus).
- Memory: Venus decode holds about 60 MiB of capture buffers for 1080p; with `MemoryMax=300M` and the live services, the device kept about 900 MiB available.

## Driver bug: STREAMOFF after an unfinished encoder drain wedges the SoC (2026-11-05, not investigated)

Kernel: baseline #10 (`7.3.0-g755ffc44d5d8-dirty #10 SMP PREEMPT Thu Nov 5 11:06:08 JST 2026`, `kernel/patches` with `0702`-`0704` and the APSS watchdog). Every control at its default, no `VIDIOC_S_PARM`, 490x652, MMAP buffers. Reproducer: `venus-enc-streamoff-after-stop.c` (compiles; not run, it hangs the device).

Sequence (from an ioctl trace of the `tsvcam` encoder, each call printed and flushed over adb before it was made, 2026-11-05 11:19):

1. formats, buffers, streaming in `v4l2-ctl`'s order; 30 frames encoded normally (30 raw buffers in and back, 31 bitstream buffers with data);
2. `VIDIOC_ENCODER_CMD` `V4L2_ENC_CMD_STOP`; the driver queues an empty EOS input buffer (`device_addr` 0 on HFI 3xx);
3. the firmware returns one empty CAPTURE buffer (`bytesused 0`, flags `0x4001`) **without** `V4L2_BUF_FLAG_LAST` (the driver sets LAST only from `HFI_BUFFERFLAG_EOS`), so `enc_state` stays `VENUS_ENC_STATE_DRAIN`; the client waits 3 s for LAST, then
4. `VIDIOC_STREAMOFF` on OUTPUT: the last line of the trace. The board stops answering; nothing is logged (the streamed kernel log and the hung boot's journal end at the start of the process); the watchdog resets it.

`v4l2-ctl` sends the same stop and gets the same empty buffer (session 3 ioctl log), but never calls `STREAMOFF`: it closes the file descriptor, and the m2m release stops CAPTURE before OUTPUT. A `tsvcam` run that ends the same way (stop, wait for the empty buffer, unmap, close; no `STREAMOFF`) encoded and exited cleanly (11:23) and so did the clip measurements after it. All five hangs (2026-11-04 17:33 and 17:55, 2026-11-05 11:09, 11:14 and 11:19) went through `STREAMOFF` OUTPUT after the stop; the queue-order and control changes tried at 11:09 and 11:14 were beside the point.

Two problems for a driver investigation: the encoder drain does not end with a LAST buffer on this firmware (the empty EOS input may be refused, like the undersized frames before `0702`), and stopping OUTPUT while the drain is pending hangs the SoC instead of failing (`venus_helper_vb2_stop_streaming()`: session stop/unload/deinit with the firmware still holding the EOS buffer is the place to look).

## What is needed from the integrator / user

- Done (2026-11-04): `0702`-`0704` accepted into `kernel/patches/`; baseline #9 runs them. The debug patch is not for acceptance.
- The ffmpeg fix is optional (user decision, 2026-11-04). Nothing planned on the tablet decodes video: camera clips only need encoding, which the app does through V4L2 directly, and MP4 muxing does not touch ffmpeg's V4L2 wrapper. If ffmpeg decoding on Venus is ever wanted (playback on the screen), the image carries the patched build, as with the kernel patches. Sending it to ffmpeg-devel is only to stop carrying it, and only if the user chooses to.
- `0704` changes the encoder's default crop to the requested size; that is a behaviour change for clients that relied on the padded size, worth a note when it goes upstream.

## Left on the device

- `/var/tmp/tsv-camcodec/bin/` (shared with the camera stream): `ffmpeg`, `ffprobe`, `libx264.so.165`, `device-test.sh`. Test media and outputs deleted. Remove with `rm -rf /var/tmp/tsv-camcodec`.
- The baseline kernel is installed; `deploy-to-device.sh` keeps `/boot/*.prev` and `/usr/lib/modules/7.3.0-g755ffc44d5d8-dirty.prev.tar` (both from the same baseline, as before).

## Roadmap

1. Done: `0702`-`0704` verified (sessions 6-7).
2. Camera to Venus H.264 in the app: `tsvcam` NV12 frames into the encoder in-process (V4L2 M2M directly, no ffmpeg), cost against the libx264 figures.
