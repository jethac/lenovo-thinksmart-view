# Camera stream — notes

Front camera: Samsung S5KC505A (QTech module, `EepromName=qtech_s5kc505a`) on CCI master 0, CSIPHY 0 / CSID 0, two data lanes. Goal: preview and stills through libcamera, lens cover respected.

## Status (2026-10-30)

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

## Left on the device

- `v4l-utils` 1.32.0-2 and `evtest` 1.36-1 (and dependency `libjpeg-turbo`) installed by this stream on 2026-10-19 device time, from Arch Linux ARM `extra` (checksums in `downloads/pkgs/SHA256SUMS`). Needed for testing; the image build should add `v4l-utils` when the camera lands.

## Correction to `devices/camera/ANALYSIS.md`

Its CCI address `0x36` (and the wiring table's VDIG/VANA/VIO GPIO association) should read: address **0x37** (proven on the wire), VDIG `pm8953_l2` 1.2 V + GPIO 118 enable, VANA `pm8953_l17` 2.85 V + GPIO 119 enable, VIO `pm8953_l6` 1.8 V; 2 lanes at 480 MHz; GRBG RAW10; five modes as above.

## Roadmap

1. **Accept 0401–0403** (integrator): they build clean on the baseline and are device-tested to raw frames. Add `CONFIG_VIDEO_S5KC505A=m` to `lenovo-cd-18781y.config`. Fix `deploy-to-device.sh` reboot detection (above).
2. **Driver polish** before sending anywhere: trace the `media-ctl -V` EINVAL for the smaller modes; add `V4L2_CID_DIGITAL_GAIN` (`0x020e`–`0x0215`, 0x0100 = 1x); group hold (`0x0104`) around exposure/gain/vblank writes; `HFLIP`/`VFLIP` via `0x0101` with the Bayer code following; mode 4 (640x490, 129 MHz link) as a second link frequency; check `0x0000`-marker writes can be dropped; consider `dt_binding_check`-clean `orientation`/`rotation` examples (done) and upstream naming review.
3. **libcamera**: build or install libcamera (Arch ARM `libcamera` + `libcamera-ipa`), check the simple pipeline handler matches `qcom-camss` on msm8953 (VFE RDI path, software ISP, `SGRBG10P`), add a sensor helper/properties entry for `s5kc505a` (analogue gain code = 32 × gain, black level 64, unit cell 1.4 µm, 2608x1960 active), then `cam -l`, `cam -c1 --capture=10 --file`, and a stills JPEG via `cam`/`qcam`. Rotation 270 is in the DT; check libcamera reports it and that the compositor/app rotates. The software ISP needs AWB/AGC; the vendor chromatix tuning is not reusable directly.
4. **Preview path**: PipeWire libcamera SPA plugin → a GStreamer or Hyprland-side viewer; measure CPU cost of the software ISP at 1304x980 (likely the preview mode) vs 1936x1096.
5. **Lens cover policy**: confirm the closed state reads `SW_CAMERA_LENS_COVER` = 1 by sliding the shutter; then enforce it outside the test script (a WirePlumber/udev policy or a small daemon that stops/blocks capture when the switch is set; a kernel-side option would be a privacy control in the sensor driver, but GPIO 87 is owned by `gpio-keys`).
6. **EEPROM/OTP**: the stock DT has an EEPROM slot on the same CCI master; probe `0x50`-`0x57` and the sensor's own OTP (`0x0a02` page select, `0x0a00` control) for lens-shading/WB data; none is shipped as a parser lib.
7. **Image build**: add `v4l-utils` (and libcamera once used) to `rootfs/scripts/` package list.
