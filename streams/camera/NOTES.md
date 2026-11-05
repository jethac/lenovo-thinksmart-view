# Camera stream — notes

Front camera: Samsung S5KC505A (QTech module, `EepromName=qtech_s5kc505a`) on CCI master 0, CSIPHY 0 / CSID 0, two data lanes. Goal: usable colour stills and a low-rate frame stream for the assistant, lens cover respected.

## Status (2026-11-04)

| Step | State |
| --- | --- |
| Driver 0401-0403 | in the baseline |
| Colour frames, AE, AWB, JPEG | **done**: `tsvcam/` (library + tool), measured beside the live services, see "Usable images" |
| Stream 490x652 at 6 fps | 6.08 fps, 32 ms CPU per frame (convert + JPEG), 0.2 core, 19 MiB RSS |
| Full-resolution still 1960x2608 JPEG | 2.46 s from open to JPEG, 0.45 s CPU, 43 MiB RSS |
| Mode-change EINVAL | found and fixed: `kernel/patches-wip/camera/0404` (plus a workaround in `tsvcam` for kernels without it) |
| libcamera 0.7.2 | works only with `system_heap` loaded and a private prefix; not chosen, see "libcamera evaluation" |
| Lens cover | enforced in the library (open refuses, every frame re-checks); closed state still not seen on hardware |

## Status (2026-10-30, raw frames)

| Step | State |
| --- | --- |
| Vendor library decoded (init, modes, exposure/gain, power) | done, see "Extracted" |
| Driver approach | custom V4L2 driver, CCI regmap, SMIA-style register map (see "Why not CCS") |
| Patches 0401 binding, 0402 driver, 0403 board DT | build clean on the baseline (`kernel/build-camera`) |
| Chip ID over CCI on the device | **done**: `0x5034` at `0x37` on CCI master 0, every boot of the stream kernel |
| Raw frames | **done**: RAW10 GRBG through CSIPHY0 → CSID0 → ISPIF0 → VFE0 RDI0 at 2608x1960 (30.08 fps measured), 1304x980 and 1936x1096; colour bars bit-exact, real scene images |
| libcamera | not started (next step) |

## Files

- `kernel/patches-wip/camera/0401-dt-bindings-media-i2c-add-samsung-s5kc505a.patch`: `samsung,s5kc505a` binding.
- `kernel/patches-wip/camera/0402-media-i2c-add-samsung-s5kc505a-sensor-driver.patch`: `drivers/media/i2c/s5kc505a.c`, Kconfig, Makefile.
- `kernel/patches-wip/camera/0403-arm64-dts-qcom-cd-18781y-front-camera.patch`: rails, CAMSS port 0, CCI, sensor node, pins; pins `pm8953_l2` at 1.2 V.
- `kernel/config/wip-camera.config`: `CONFIG_VIDEO_S5KC505A=m` (CAMSS, CCI, MC and subdev API are already in the baseline config, listed for completeness). **Needs into `lenovo-cd-18781y.config` via the integrator: `CONFIG_VIDEO_S5KC505A=m`.**
- `streams/camera/build-camera.sh`: `build.sh` steps on `wt-camera` into `build-camera` with the fragment.
- `streams/camera/device-test.sh`: runs on the device: `probe` (modules, log, nodes), `capture [WxH]` (media-ctl pipeline, RDI0 raw capture, 4 frames saved plus a 40-frame fps measurement; refuses when the lens cover reads closed; `EXPOSURE=` lines and `GAIN=` code from the environment), `pattern [WxH]` (same with colour bars, no scene content), `cover`.
- `streams/camera/tools/raw10-preview.py`: packed RAW10 → half-resolution PPM plus per-channel stats (stdlib only).
- `streams/camera/tools/extract-sensor-lib.py`: decodes `sensor_lib_t` from the vendor library into text (`--c` for C tables). Output: `streams/camera/s5kc505a-sensor-lib-decode.txt`.
- `streams/camera/work/` (not in git): `vendor/` extracted libraries and XML from `vendor.img`, decode outputs, the dtschema venv.

## Extracted from `libmmcamera_s5kc505a.so`

Library: sha256 `3d90f268…5e99`, same as `devices/camera/evidence/libmmcamera_s5kc505a.so`. `sensor_open_lib()` returns VA `0x4008`; `.data` VA `0x4000` = file `0x3000`. Layout of `sensor_lib_t` worked out from the data (fixed strides, `{addr_type 2, data_type 1, delay}` tails, the power-setting enums) and cross-checked against the sibling `ov5693` and `s5k4e8` libraries.

| Item | Value | Confidence |
| --- | --- | --- |
| I2C address | 8-bit `0x6e` → **7-bit `0x37`**. Same field is `0x6c` (OV5693, its real address `0x36`) and `0x5a` (S5K4E8, `0x2d`). rickx saw the module answer at `0x37` on a powered probe. The `0x36` in `devices/camera/ANALYSIS.md` came from a byte that is the same in all three libraries, i.e. not per-sensor; it is wrong. | high |
| Bus | 400 kHz, 16-bit register address, 8-bit data | high |
| Chip ID | `0x0000` (16 bit) = `0x5034`. rickx also read `0x300a` = `0x5203` | high |
| MCLK | 24 MHz (power table, stock DT `qcom,clock-rates`, and `0x0136` = `0x18` in the mode tables) | high |
| Power up | reset low, standby low (1 ms each); VANA reg + GPIO VANA high (1 ms); VDIG reg + GPIO VDIG high (1 ms); VIO reg; MCLK (1 ms); reset high (10 ms); standby high (10 ms) | high (raw records checked) |
| Power down | standby low, reset low, MCLK off (1 ms each), VIO, VDIG, VANA off. GPIO 118/119 not driven low by the library | high |
| Output | Bayer RAW10, GRBG at orientation 0 (`0x0101` = 0), MIPI CSI-2 VC0 DT `0x2b`, 2 lanes | high for format/lanes; Bayer order medium until a frame is looked at |
| Pixel array | 2608 x 1960 active, 8 dummy pixels each side, 1.4 µm, white 1023, black 64 | high (decoded), medium (semantics of the dummy fields) |
| Init | 45 writes, then mode table. First four are `0x0000` = `0x10 0x60 0x04 0xe8`: Samsung setfile version markers (`0x04e8` is the S5K4E8 chip ID), harmless writes to a read-only register; kept as stock does. `0x0a02` = `0x0f` then 10 ms. | high (bytes), medium (meaning) |
| Same tables as S5K4E8 | init, modes, PLL and output data are byte-identical to `libmmcamera_s5k4e8.so` apart from address, chip ID and one extra S5K4E8 init write (`0x392f` = `0x01`). The S5KC505A looks like an S5K4E8 derivative. | high |
| Start / stop | `0x0100` = 1, `0x0101` = 0 / `0x0100` = 0. Group hold `0x0104` = 1 / 0 | high |
| Exposure | coarse `0x0202` (16 bit), frame length `0x0340`, line length `0x0342`; exposure ≤ frame length − 8 | high |
| Gain | analogue `0x0204` (16 bit), 32 = 1x, clamp 32…511 (vendor max 15.97x); per-channel digital `0x020e/0x0210/0x0212/0x0214` = `0x0100` (1x) | high (registers), medium (digital gain format) |
| Test pattern | `0x0600` = 0…4 (off, solid, bars, fade bars, PN9), solid colour `0x0602–0x0608` | high (registers), medium (pattern meanings from SMIA) |
| PLL | `0x0305` pre-div 4, `0x0306/7` mult 95, `0x0301` vt_pix div 6 → 190 Mpix/s (two pixels per clock); op: `0x030d` 4, `0x030f` 160 → 960 Mb/s per lane, link 480 MHz. Same in modes 0–3 | high (decode), medium (PLL interpretation; matches the vendor's 190 MHz for mode 0) |

Modes (vendor table; fps from line × frame length at 190 Mpix/s):

| # | Output | Readout | line × frame | fps | Link | Driver |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 2608 x 1960 | full | 3112 × 2030 | 30.1 | 480 MHz | yes |
| 1 | 1304 x 980 | 2x2 binned full | 3112 × 2030 | 30.1 | 480 MHz | yes |
| 2 | 1936 x 1096 | centre crop | 2760 × 1166 | 59.0 (vendor: 60) | 480 MHz | yes |
| 3 | 1296 x 736 | 2x2 binned crop | 2760 × 806 | 85.4 (vendor: 90/85) | 480 MHz | yes |
| 4 | 640 x 490 | binned + skipped | 2800 × 565 | 120 | 129 MHz | no (needs a second link frequency) |

The vendor lists vt_pix_clk 200 MHz for mode 2 and 189.09 MHz for mode 3 although the PLL registers are unchanged; the driver uses 190 MHz for all modes.

Board, from the stock DT (`camera@0`; `camera_config.xml` CameraId 0 → CSIDCore 0):

| Item | Value |
| --- | --- |
| VANA | `pm8953_l17` 2.85 V, gated by GPIO 119 (`CAM_VANA`) |
| VDIG | `pm8953_l2` 1.2 V (stock regulator range 0.975–1.225 V, `always-on`, no other consumer), gated by GPIO 118 (`CAM_VDIG`) |
| VIO | `pm8953_l6` 1.8 V |
| MCLK | GPIO 26 `cam_mclk` (MCLK0), 24 MHz |
| Reset / standby | GPIO 40 / GPIO 39, both low = held |
| CSI | CSIPHY 0, CSID 0, LaneMask `0x7`, LaneAssign `0x4320` (downstream numbering 0 = D0, 1 = CLK, 2 = D1) → mainline 3-phase PHY `data-lanes = <0 1>`, `clock-lanes = <7>` |
| Mount | front, 270° |
| `camera@2` (CSIPHY 2, MCLK2 GPIO 28, reset 131, standby 132) | enabled in stock but nothing bound there on this unit; not described |
| Actuator / EEPROM | slots exist; S5KC505A config has no actuator lib and no EEPROM lib (`qtech_s5kc505a` has no matching .so) → fixed focus, no OTP parser shipped |

## Why not CCS

The register map is SMIA-shaped, but `ccs` needs the CCS identification/limits space (`0x1000+`) to be correct or a static-data firmware file per module, plus the vendor's 45 undocumented `0x3xxx`/`0x0a02` init writes before streaming. Its PLL calculator would choose different divider settings from the tested vendor tables. A small table-driven driver (in the style of the recent `v4l2-cci` sensor drivers) reproduces the stock behaviour register for register and keeps the risk low. The probe logs `0x0002`–`0x0004` (revision, manufacturer, SMIA version) so CCS can be reconsidered later.

## Driver (0402) summary

`s5kc505a.c`: CCI regmap (16-bit address), runtime PM with the vendor power order, chip-ID check with retries (and, if nothing answers, a one-shot read at the other candidate address so a wrong DT address shows up in one boot), four modes on one 480 MHz link frequency, controls: link freq, pixel rate, hblank (ro), vblank, exposure, analogue gain, test pattern, orientation/rotation from DT. Streams the vendor init + mode table, then `0x0101` = 0 and `0x0100` = 1.

## Changes made in this round (over the earlier draft)

- CAMSS endpoint lanes: `<0 2>` / clock 1 → `<0 1>` / clock 7. The 3-phase CSIPHY driver used on msm8953 maps data lane n to PHY lane 2n and always uses lane 7 as the clock, so the old value would have enabled D2 instead of D1. Matches the in-tree msm8953 phones (`msm8953-xiaomi-daisy.dts`).
- Pixel rate 190 MHz for every mode (was the vendor's per-mode numbers).
- Makefile entry in alphabetical order.

## Device results (2026-10-30, stream kernel `7.3.0-g6d6139037b4e-dirty`)

Three locked sessions; logs in `work/session{1,2,3}.log`, captures in `work/session{2,3}/` (not in git; the scene frames show a person in the room, keep them out of the repo).

- **Session 1 did not test anything**: `deploy-to-device.sh --reboot` ran `adb reboot`, which printed `error: closed` and did **not** reboot (uptime unchanged, no new boot ID), yet `wait_back` reported "back" because adb still answered. The rollback then restored the same files. **For the integrator:** `wait_back` should compare `/proc/sys/kernel/random/boot_id` before and after (and the expected `uname -r`); `systemctl reboot` over adb worked every time. Sessions 2 and 3 installed without `--reboot`, rebooted with `systemctl reboot` and checked the boot ID and kernel release.
- **Probe** (sessions 2 and 3, every boot): `s5kc505a 3-0037: chip id 0x5034, revision 0x00, manufacturer 0x00, smia 0x0a, 0x300a 0x5203`. The module answers at **0x37**; manufacturer ID is not programmed and the SMIA version reads 1.0, which supports the custom-driver decision. CAMSS, CCI and the sensor probe at boot with no errors (only the expected "Fixed dependency cycle" notes between the sensor and CAMSS graph nodes). Rails while idle: `cam_vddd` (L2) 1.2 V, `cam_vdda` (L17) 2.85 V, L6 1.8 V, all disabled after runtime suspend; GPIO 39/40/118/119 driven low; MCLK pin in `cam_mclk` function.
- **Lens cover**: `SW_CAMERA_LENS_COVER` = 0 (GPIO 87 high), and the scene frames show the room, so "0 = open" is confirmed. The closed state has not been seen yet (needs someone to slide the shutter); `device-test.sh capture` refuses when it reads 1.
- **Session 2**: the entity name is `s5kc505a 3-0037` (with a space), which the first script version mishandled, so the test pattern was not set; the CAMSS links and formats were set anyway (sensor → CSIPHY0 is an immutable link) and 4 full frames came back: a dark room at 1x gain with one lamp, clean framing. This validated lanes (`data-lanes = <0 1>`), RAW10 packing and the VFE stride (3264 bytes for 2608 px).
- **Session 3** (fixed script, rebuilt on the base config with ZRAM/PSI):
  - 2608x1960 colour bars: **exact SMIA bars, white-yellow-cyan-green-magenta-red-blue-black, when decoded as GRBG** → Bayer order GRBG confirmed, data path bit-exact. **30.08 fps** measured (= 190 MHz / (3112 × 2030), so the PLL reading is right).
  - 2608x1960 scene at exposure 2022 lines, analogue gain 256 (8x): a recognisable room and person, rotated 90° as the 270° mount predicts, green cast as expected from raw data without white balance or black-level subtraction.
  - 1304x980 (binned) scene and 1936x1096 (centre crop) colour bars: correct images (strides 1632 and 2424). For these two modes one of the `media-ctl -V` calls printed `Unable to setup formats: Invalid argument`, but the pipeline formats ended up right; to be traced (probably a pad that keeps the previous size until the link is reset).
- Device put back on the baseline after each session (boot ID and release checked; `/boot/Image.gz` and the dtb hash-identical to `kernel/build-7.3`), stream modules directory and `/boot/config-7.3.0-g6d6139037b4e-dirty` removed. `deploy-to-device.sh` itself leaves `/usr/lib/modules/7.3.0-g755ffc44d5d8-dirty.prev.tar`.

## Usable images: `tsvcam` (2026-11-04, baseline kernel)

### Approach and why

Two candidates were tried on the device: libcamera's simple pipeline handler with its software ISP, and a small in-process pipeline. The in-process one, `tsvcam/`, is the one to use:

- **Dependencies.** `tsvcam` needs only `libturbojpeg` (already in the image through `libjpeg-turbo`); the tool is 50 KB, the shared library 44 KB. libcamera 0.7.2 from Arch Linux ARM links `libEGL`/`libGLESv2` (Mesa and LLVM, about 200 MB installed, not in the image), `libpisp`, `libyuv`, `libyaml`, and its `cam` tool links SDL2. It was run from a private prefix with stub EGL/GLES/SDL2 libraries (CPU ISP only).
- **It works without kernel or image changes.** libcamera's software ISP needs a dma-buf heap; the baseline builds `CONFIG_DMABUF_HEAPS_SYSTEM=m` but nothing loads it, so out of the box libcamera only delivers raw Bayer. With `modprobe system_heap` it does produce RGB (below), and `/dev/dma_heap/system` is root-only.
- **Fit to the job.** The app needs a photo, a low-rate frame stream, the lens cover enforced and a cheap change signal; `tsvcam` does exactly that in-process, with AE using the sensor's real gain code, a 50/60 Hz flicker rule and the frame length, and with the 270° mount corrected. libcamera has no sensor helper or properties for the S5KC505A (it warns and treats the gain code as linear, uses `uncalibrated.yaml`, assumes control delays) and does not rotate.

libcamera stays the route if the device ever needs a general camera (PipeWire, browsers); what it would take is in the roadmap.

### Pipeline

`tsvcam/tsvcam.c` (MIT; header `tsvcam.h`):

1. Media graph set up with ioctls (no `media-ctl`): resets links, sensor → CSIPHY0 → CSID0 → ISPIF0 → VFE0 RDI0, `SGRBG10_1X10` on every pad, `SGRBG10P` (`pgAA`) on `msm_vfe0_video0`, 3 MMAP buffers (multiplanar).
2. Lens cover: `gpio-keys` `SW_CAMERA_LENS_COVER` read with `EVIOCGSW` before streaming and before every frame; closed (or no switch found) refuses with `TSVCAM_ECOVER` and stops the stream.
3. Each frame is copied out of the V4L2 buffer and the buffer requeued at once. Holding it for a 50 ms demosaic starved the RDI ping-pong and the sensor's frames arrived at 2.4 fps instead of 20; with the copy, 6.1 fps.
4. Statistics on about 6000 Bayer quads per frame: mean green, a 64-bin histogram, grey-world sums (unsaturated, not black), and a 16x12 luma grid returned with the frame for change detection.
5. AE: target mean linear green 0.16; the brightest 2 % kept below clipping, but not at the price of a mean under 0.6 x target (this has a fixed point, so AE settles with lamps in view). Exposure first (up to 66 ms for the stream, 100 ms for stills), snapped to 10 ms steps above 10 ms for 50 Hz lighting (`flicker_hz`), frame length (`VBLANK`) stretched as needed, then analogue gain (code 32 = 1x up to 511), then up to 4x digital gain in the tables. New settings are applied in the order the driver's exposure limit needs and the next 3 frames are not used for AE.
6. AWB: grey world, smoothed (0.35 per frame), gains 0.6-4.0.
7. Conversion: per-channel tables (black level 64, white balance, digital gain → 12-bit linear), then a saturation matrix (1.35, preserves grey; no calibrated colour matrix exists) on planar rows (vectorised), sRGB gamma, and the rotation written through 16-row strips. Two outputs: **half** (one RGB pixel per 2x2 quad: W/2 x H/2) and **full** (bilinear demosaic).
8. JPEG through `tj3Compress8` (4:2:0, fast DCT), and NV12 (BT.601 limited) for video encoders.

Rotation: the sensor reports 270 (counter-clockwise correction), so frames are turned 90° clockwise; output is portrait (for example 490x652). In a frame of the room the whiteboard text is horizontal with its tray at the bottom, so this is upright for the tablet standing in portrait.

### Measurements

Beside the live services (`straylight-listen` about 1.0 GiB RSS, 900 MiB available), each run in `systemd-run -p MemoryMax=200M`, Cortex-A53 at `schedutil`. Room lit by ceiling LEDs. `streams/camera/tsvcam/device-bench.sh`.

| Run | Rate | CPU per frame (convert + JPEG) | CPU share | Output | RSS |
| --- | --- | --- | --- | --- | --- |
| Stream, binned 1304x980 → 490x652 (quad), 6 fps | 6.08 fps | 22.5 + 9.8 ms | 0.20 core | 34 KB JPEG | 19 MiB |
| Stream, binned → 980x1304 (demosaic), 6 fps | 6.12 fps | 48.5 + 21.1 ms | 0.44 core | 98 KB | 19 MiB |
| Stream, crop 1936x1096 → 548x968 (quad), 6 fps | 6.15 fps | 30.1 + 12.5 ms | 0.28 core | 52 KB | 19 MiB |
| Stream, binned → 490x652, as fast as possible | 19.4 fps (sensor at 20 fps, 50 ms exposure) | 17.6 + 7.7 ms | 0.51 core | | 19 MiB |
| Still, full 2608x1960 → 1960x2608 (demosaic) | 2.46 s open to JPEG (2.5 s AE budget) | 243 ms convert | 0.45 s CPU total | 576 KB | 43 MiB |
| Still, full readout → 980x1304 (quad) | 1.1-1.5 s | 76-98 ms | 0.2 s CPU total | 166 KB | 25-31 MiB |

Conversion cost without the camera (`tsvcam bench`, synthetic frame, 90° rotation): full readout quad 48.8 ms / demosaic 184 ms; binned quad 11.3 ms / demosaic 46.8 ms; crop quad 19.2 ms / demosaic 75.6 ms (JPEG adds 6.6-96 ms). The live services' RSS and load were unchanged across the runs.

AE settled in 8-10 frames from the default start (60 ms, 1.1x) in this room: 40-50 ms at 1.0-1.3x, mean 0.11-0.13 (highlight rule active: ceiling lights in view), WB R/B gains about 1.6/2.1-2.4. The full-readout still reported "AE not converged" once: the 2.5 s budget ended on a step; the image was correctly exposed.

### libcamera evaluation

libcamera 0.7.2 (Arch Linux ARM `libcamera`, `libcamera-ipa`, `libcamera-tools` 0.7.2-4, `libpisp` 1.5.0, `libyuv` r2921, `libyaml` 0.2.5; SHA-256 from the repository databases, packages in `downloads/pkgs/`), unpacked to a private prefix; `streams/camera/libcamera-eval.sh`.

- The simple pipeline handler matches `qcom-camss` on msm8953 and finds the camera through RDI0: `cam -l` lists "Internal front camera", with raw modes 1296x736, 1304x980, 1936x1096 and 2608x1960 (`SGRBG10_CSI2P`).
- Warnings on every start: no static properties for `s5kc505a`, no sensor delays ("assuming unverified defaults"), no camera sensor helper (soft IPA uses the gain code as-is), no `s5kc505a.yaml` tuning (falls back to `uncalibrated.yaml`).
- Without a dma-buf heap: "Could not open any dma-buf provider", software ISP disabled, raw frames only (1304x980 RAW10, 30 fps).
- With `modprobe system_heap`: RGB888 at 1304x980 delivered at 59 fps, so libcamera picked the 1936x1096 crop mode and scaled it (narrower field of view than the binned full readout); frames unrotated; exposure and colour plausible. The run used 2.4 s CPU for 60 frames including writing 230 MB of frames, and a 209 MiB memory peak (includes those files in page cache), so it is not a clean cost figure. The 2608x1960 request produced no frames. `system_heap` could not be unloaded afterwards (in use until reboot).

To make libcamera first-class: load `system_heap` at boot (and give the camera user access to `/dev/dma_heap/system`), add an `s5kc505a` entry to libcamera's sensor properties (unit cell 1.4 µm, delays: exposure 2, gain 2 frames, as `tsvcam` uses) and a sensor helper (gain = code / 32, black level 64 at 10 bits), a tuning file, and Mesa if the GPU ISP is wanted.

### Fix found on the way: `0404`

`kernel/patches-wip/camera/0404-media-i2c-s5kc505a-accept-the-read-only-timing-controls.patch`. A mode change updates `HBLANK` through `__v4l2_ctrl_modify_range()`, which calls `s_ctrl`; while the sensor is still runtime-active (1 s autosuspend after a stream) `s_ctrl` hit `default: -EINVAL`, so `VIDIOC_SUBDEV_S_FMT` failed after the mode had already switched and left the `VBLANK`/`EXPOSURE` ranges of the old mode. This is the `media-ctl -V` "Invalid argument" seen on 2026-10-30. The patch makes `HBLANK`, `PIXEL_RATE` and `LINK_FREQ` no-ops in `s_ctrl`. Tested on the device (kernel `build-video-codec` = baseline + 0404 + 0701): crop and full-readout opens right after another mode, which failed on the baseline. Until it is accepted, `tsvcam` waits for the sensor to runtime-suspend (up to 2 s) before changing mode.

### Clips: Venus encoder, MP4 writer, change selection (2026-11-04/05)

- **Encoder** (`tsvcam-clip.c`): opens `qcom-venus-encoder` by name, single-plane NV12 in, H.264 out, MMAP buffers (4 + 4), RGB frames converted straight into the encoder's buffer in its own layout (bytesperline x format height before the chroma plane), timestamps carried through, `V4L2_ENC_CMD_STOP` and a wait for the LAST buffer at the end. No ffmpeg.
- **MP4 writer** (`mp4mux.c`): Annex B access units in, SPS/PPS moved to `avcC`, samples length-prefixed, `ftyp`+`moov`+`mdat` with the index first, `stts` from the real timestamp differences, `stss` from IDR slices. Checked on the laptop with the 60-frame Venus stream of camera frames from the video-codec session 7: 60/60 frames decode, each identical to decoding the raw stream, 116.8 KB, 10.0 s, deliberately uneven timestamps preserved, 2 sync samples.
- **Selection** (`tsvsel.c`): see the API proposal. Synthetic test (6 s at 6 fps, 5 s window): still scene with noise and an AE ramp keep 5 frames (first + 1/s; scores up to 0.057 against 0.12), an object appearing at 2 s is kept at exactly that frame, a moving hand or a changing scene keeps 30 frames spread over the window.
- **Device results (2026-11-05, baseline #10).** After five hangs traced to `VIDIOC_STREAMOFF` on OUTPUT after an unfinished encoder drain (driver bug, `streams/video-codec/NOTES.md`), the encoder ends like `v4l2-ctl`: stop, wait for the firmware's empty buffer, unmap, close, no `STREAMOFF` (`TSVCAM_VENC_EXPLICIT_STREAMOFF` keeps the old way, for reproducing only). Default settings: no frame interval, no controls (driver default rate, about 1 Mbit/s; IDR every 30 frames), `v4l2-ctl`'s queue order. Measured beside the live services (`straylight-listen` 1.36-1.43 GiB RSS, about 1 GiB available), `systemd-run -p MemoryMax=200M`:

| Run (490x652) | Frames | MP4 | CPU | RSS |
| --- | --- | --- | --- | --- |
| `venctest`, 30 synthetic frames, encoder only | 30/30 | 124 KB, 5.0 s; 0.30 s wall | | |
| `clip` defaults (5 s window, threshold 0.12, someone walking into view) | 20 of 32 kept (19 change) | 362 KB, 3.33 s (compact) | 1.05 s for the whole clip incl. 1 s AE settle | 20 MiB |
| `clip --threshold 0` (every frame, min gap 1/6 s) | 24 of 32 | 454 KB, 4.0 s | 1.07 s | 20 MiB |
| same, `--real-time` | 24 | 553 KB, 5.05 s | 1.03 s | 21 MiB |
| capture + NV12 only, 30 frames (shared by both encoders) | | | 0.92 s | 9.5 MiB |
| capture + libx264 ultrafast, 1 thread, 1.5 Mbit/s | 30 | 1.02 MB | 0.92 + 0.97 s | 9.5 + 16 MiB |
| capture + libx264 veryfast, 1 thread | 30 | 0.97 MB | 0.89 + 2.56 s | 9.5 + 38 MiB |

  The Venus encode itself costs about 0.1 s of CPU per 5 s clip and the encoder drains in 4-5 ms after the last frame; libx264 needs 1-2.6 s of CPU for the same frames. Every clip decodes with ffmpeg's software decoder on the laptop: 20, 24, 24 frames, no errors, one keyframe each. Clips (captures) are on the Shared partition only.
- **Threshold calibration.** `tsvcam scores -n 60` on the room: while a person moved in view the frame-to-frame score was 0.13-1.28; once the scene was still it sat at 0.026-0.028 for 40 frames (median 0.027). The default 0.12 is about 4.4 times the still-scene floor and below every frame with someone moving, so it stays. Global changes the selector ignores by design: AE moving the overall level (normalised out).

### API proposal for the app (revised 2026-11-04: photo, clip, cover)

The app links `libtsvcam.a` (C; `tsvcam.h`) and calls it from one dedicated camera thread; nothing in the library is thread-safe and only one camera user can exist at a time (`Busy` otherwise). Three calls cover the conversation features:

```rust
enum CamError { CoverClosed, NoDevice, Busy, Io, Timeout, TooBig }   // TSVCAM_E*

/// Photo. The app runs the countdown on screen, then calls this; the
/// call itself settles exposure for up to `settle_ms` (1000-2500) first.
/// half = true: 980x1304 JPEG, about 170 KB; false: 1960x2608, about 580 KB.
fn photo(half: bool, quality: u8 /* 85 */, settle_ms: u32) -> Result<Jpeg, CamError>;
                                                // tsvcam_photo()

/// Short video for "look at what I'm doing": samples the camera at 6 fps
/// for up to max_s, keeps frames that carry change, encodes them to H.264
/// on the Venus encoder and returns a complete MP4 in memory.
fn clip(max_s: f32, budget: ClipBudget) -> Result<Clip, CamError>;
                                                // tsvcam_clip()
struct ClipBudget {
    max_frames: u32,     // default 30
    max_bytes: usize,    // default 1100 KiB (see "limits" below)
    threshold: f32,      // change needed to keep a frame; default 0.12 (still scene 0.027)
    idle_gap_s: f32,     // a frame at least this often when nothing changes (1.0; 0 = none)
    compact_time: bool,  // default true, see "timing" below
}
struct Clip {
    mp4: Vec<u8>,        // video/mp4, H.264 Main/High, 490x652 portrait
    duration_ms: u32,    // of the MP4 (what the model is billed for)
    window_ms: u32,      // real time covered
    frames: Vec<KeptFrame>,  // per kept frame: capture time (ms from start), why kept, score
    stop: StopReason,    // Time | Frames | Bytes | Cover
}

/// Lens cover state, for the screen; photo()/clip() also refuse or stop on it.
fn cover_closed() -> Result<bool, CamError>;    // tsvcam_cover_closed()
```

`photo()` and `clip()` block (about 1.1-2.5 s and max_s + 1 s settle + well under a second to drain); run them off the UI thread. Lower-level calls (`tsvcam_open`/`next_frame` for a live preview, `tsvcam_venc_*` for the encoder alone) stay available.

**Frame selection** (`tsvsel.h`): each frame's 16x12 luma grid, divided by its own mean so exposure changes do not count, is compared with the last kept frame; the score is the mean change of the 12 most-changed cells, so a hand or a face moving in a corner counts like a scene change, and slow drift triggers once it adds up. Rules: the first frame is kept; a frame is kept when its score passes `threshold` and at least `max(1/fps, max_s / max_frames)` has passed; a heartbeat frame is kept every `idle_gap_s` when nothing changes. *Nothing changes:* the clip is the first frame plus one frame a second (5-6 frames for 5 s; under 1 s of MP4 with compact timing). *Everything changes:* one frame per `max_s / max_frames` (every frame at 6 fps with the defaults), so the budget covers the whole window. The clip ends at `max_s`, at `max_frames`, when the next frame would likely break `max_bytes`, or when the lens cover closes (the frames taken so far are returned, `stop = Cover`). Tested on synthetic grids (static, AE ramp, object appearing, moving hand, everything changing) and on the device (calibration above).

**Timing.** With `compact_time` (default) the kept frames sit 1/6 s apart in the MP4, so the model is billed for the frames kept, not the wall time: at about 260 tokens per second of 640x480-class video, a 5 s window costs about 1300 tokens with real timing, and with compact timing about 220 tokens when nothing changes (5 frames) up to 1300 when everything does (30 frames). Real capture times are in `Clip.frames`; put them in the prompt text ("frames at 0.0, 1.0, 1.4, 1.6 s") so speeds are not misread. `compact_time = false` keeps real timestamps in the MP4 (variable frame rate).

**Limits (ai& daemon: data URLs only, 1.5 MiB per item, 4 MiB per request).** A data URL is base64, 4/3 of the bytes plus the `data:video/mp4;base64,` prefix, so an item's file must stay under about 1.12 MiB: `max_bytes` defaults to 1100 KiB. Per request: at most three clips at the default size, or for example one clip plus three half-size photos (about 230 KB each as data URLs). The library cannot see the request; the app adds up the encoded sizes (`ceil(n / 3) * 4 + 22` per clip) and lowers `max_bytes` for later items. With the encoder's default rate (about 1 Mbit/s; the rate controls are untested since the hang work) 24 kept frames were 454 KB; 1100 KiB is only reached with long, busy clips.

**Cost on the tablet** (measured 2026-11-05): a 5 s clip takes about 6 s wall (1 s AE settle, 5 s window, 5 ms drain), about 1.05 s of CPU in total of which the Venus encode is about 0.1 s, 20 MiB RSS; libx264 on the same frames would add 1-2.6 s of CPU. The default clip with someone moving was 362 KB and 3.33 s of MP4 (about 870 tokens at 260 tokens/s).

**Camera-on indicator:** on while `photo()`, `clip()` or a preview stream runs; nothing touches the sensor otherwise. **Lens cover:** `CoverClosed` from any call; the app says "lens cover closed".

The `tsvcam` tool offers the same as a subprocess (`tsvcam photo -o -`, `tsvcam clip -o - -v` for the MP4 on stdout and the kept-frame table on stderr; exit code 3 = cover closed).

### Files

- `tsvcam/tsvcam.h`, `tsvcam/tsvcam.c`: library. `tsvcam/tsvcam-clip.c`: Venus encoder through V4L2 mem2mem and `tsvcam_clip()`. `tsvcam/tsvsel.c`: change-based frame selection. `tsvcam/mp4mux.c`: in-memory MP4 writer (avcC from the encoder's SPS/PPS, variable frame durations, sync samples). `tsvcam/tsvcam-cli.c`: tool (`cover`, `photo`, `stream`, `bench`, `clip`, `scores`, `venctest`).
- `tsvcam/device-clip.sh`: the clip measurements (still to run).
- `tsvcam/build.sh`: cross-build (clang + ld.lld, the asr stream's sysroot, `libjpeg-turbo` 3.2.0 package for headers) into `work/tsvcam/`.
- `tsvcam/device-bench.sh`: the measurement runs above. `libcamera-eval.sh`: the libcamera runs.
- Captures (room images) are on the laptop's Shared partition, `lenovo-8-captures/camera/`, not in the repository.

## Left on the device

- **2026-11-05 11:19-11:24: traced run named the call** (`STREAMOFF` OUTPUT after the stop; one more watchdog reset); with the close path changed, the encoder, the calibration and the clip measurements ran without a hang. Five hangs in all, one cause; see `streams/video-codec/NOTES.md`. `/var/tmp/tsv-camcodec/out/` removed; 19 MB of tools left.
- **2026-11-05 11:14: the encoder in `v4l2-ctl`'s queue order hung too** (watchdog reset, back in 15 s, `/boot` mounted). So the queue order is not the trigger; the remaining differences are listed in `streams/video-codec/NOTES.md` ("Driver bug"). Flag steps, calibration and clip measurements skipped (they all build on the step that hung). Kernel log: `/run/media/jethac/Shared/tsv-camcodec-logs/venc-bisect2-111416.dmesg.1`.
- **2026-11-05 11:09, baseline #10 (watchdog): bisect step 1 hung, the watchdog reset the tablet** (back within a minute, `/boot` mounted, services up). Step 0, the session 7 `v4l2-ctl` encode (490x652, 30 frames, driver defaults), worked; step 1, `tsvcam venctest` with all extra settings off (`--flags 0`), hung. So none of the frame-rate/rate/GOP/stream controls or buffer-size choices is the trigger. What remained different from `v4l2-ctl` is the order of the queue setup: `tsvcam` allocated and queued the CAPTURE (bitstream) buffers and streamed both queues on before any raw frame was queued; `v4l2-ctl` queues raw frames, streams OUTPUT on, then allocates and queues CAPTURE and streams it on. The encoder now uses `v4l2-ctl`'s order by default (`TSVCAM_VENC_EARLY_START` keeps the old order); to be tried in the next session, not repeating the step that hung. A user-space ioctl order that wedges the SoC is a driver problem worth reporting separately. Kernel log: `/run/media/jethac/Shared/tsv-camcodec-logs/venc-bisect-110905.dmesg` (ends at the start of the test unit; nothing from Venus). `/var/tmp/tsv-camcodec/out/` cleaned.
- **2026-11-04 17:55: hung again, encoder alone** (`tsvcam venctest`, 30 synthetic frames, 490x652, no camera), at the first open of the encoder by this code. Kernel log streamed to `/run/media/jethac/Shared/tsv-camcodec-logs/clip-session1-175526.dmesg`; its last line is the start of the test's systemd unit at uptime 110 s, nothing from Venus after it. The 17:33 hang below was the same workload, so the camera is not needed for it. Device work stopped until a watchdog is in the baseline; `/var/tmp/tsv-camcodec/out/clip/` to be cleaned at the next session.
- **2026-11-04 17:33: the tablet hung during `tsvcam clip`** (baseline #9). `tsvcam scores` (camera only) had just completed; the first clip was the first time the camera and the Venus encoder ran at the same time (earlier encodes read camera frames from a file). adb and the USB network stopped answering; the USB gadget stayed enumerated on the laptop with `cdc_ncm ... transmit queue 0 timed out` every few seconds from 17:33:06, so the kernel hung rather than rebooted. Not back after more than 3 minutes; left for a power cycle by the integrator. `/var/tmp/tsv-camcodec/out/clip/` may hold up to one partial clip (a capture) to delete afterwards.

- `/var/tmp/tsv-camcodec/` (19 MB, 2026-11-04): `bin/` with `tsvcam`, the video-codec test tools (ffmpeg, ffprobe, libx264, scripts) and `lc/` (libcamera private prefix). No captures (deleted after copying to the laptop). Remove with `rm -rf /var/tmp/tsv-camcodec`.
- `v4l-utils` 1.32.0-2 and `evtest` 1.36-1 (and dependency `libjpeg-turbo`) installed by this stream on 2026-10-19 device time, from Arch Linux ARM `extra` (checksums in `downloads/pkgs/SHA256SUMS`). Needed for testing; the image build should add `v4l-utils` when the camera lands.

## Correction to `devices/camera/ANALYSIS.md`

Its CCI address `0x36` (and the wiring table's VDIG/VANA/VIO GPIO association) should read: address **0x37** (proven on the wire), VDIG `pm8953_l2` 1.2 V + GPIO 118 enable, VANA `pm8953_l17` 2.85 V + GPIO 119 enable, VIO `pm8953_l6` 1.8 V; 2 lanes at 480 MHz; GRBG RAW10; five modes as above.

## Roadmap

1. **Accept 0401–0403** (integrator): they build clean on the baseline and are device-tested to raw frames. Add `CONFIG_VIDEO_S5KC505A=m` to `lenovo-cd-18781y.config`. Fix `deploy-to-device.sh` reboot detection (above).
2. **Driver polish** before sending anywhere: accept `0404` (the `media-ctl -V` EINVAL, found and fixed 2026-11-04); add `V4L2_CID_DIGITAL_GAIN` (`0x020e`–`0x0215`, 0x0100 = 1x); group hold (`0x0104`) around exposure/gain/vblank writes; `HFLIP`/`VFLIP` via `0x0101` with the Bayer code following; mode 4 (640x490, 129 MHz link) as a second link frequency; check `0x0000`-marker writes can be dropped; consider `dt_binding_check`-clean `orientation`/`rotation` examples (done) and upstream naming review.
3. **App integration** (other stream): link `libtsvcam` per the API proposal; add `tsvcam` to the image (`rootfs/scripts/`) with the app.
4. **libcamera** (only if a general camera is wanted; evaluated 2026-11-04, see above): build or install libcamera (Arch ARM `libcamera` + `libcamera-ipa`), check the simple pipeline handler matches `qcom-camss` on msm8953 (VFE RDI path, software ISP, `SGRBG10P`), add a sensor helper/properties entry for `s5kc505a` (analogue gain code = 32 × gain, black level 64, unit cell 1.4 µm, 2608x1960 active), then `cam -l`, `cam -c1 --capture=10 --file`, and a stills JPEG via `cam`/`qcam`. Rotation 270 is in the DT; check libcamera reports it and that the compositor/app rotates. The software ISP needs AWB/AGC; the vendor chromatix tuning is not reusable directly.
5. **Preview path**: PipeWire libcamera SPA plugin → a GStreamer or Hyprland-side viewer; measure CPU cost of the software ISP at 1304x980 (likely the preview mode) vs 1936x1096.
6. **Lens cover policy**: confirm the closed state reads `SW_CAMERA_LENS_COVER` = 1 by sliding the shutter; then enforce it outside the test script (a WirePlumber/udev policy or a small daemon that stops/blocks capture when the switch is set; a kernel-side option would be a privacy control in the sensor driver, but GPIO 87 is owned by `gpio-keys`).
7. **EEPROM/OTP** (would also give lens shading; frames show mild vignetting and no colour calibration): the stock DT has an EEPROM slot on the same CCI master; probe `0x50`-`0x57` and the sensor's own OTP (`0x0a02` page select, `0x0a00` control) for lens-shading/WB data; none is shipped as a parser lib.
8. **Image build**: add `v4l-utils` (and libcamera once used) to `rootfs/scripts/` package list.
