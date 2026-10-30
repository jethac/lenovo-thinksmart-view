# idle-rotate

Gravity-following ai& idle screen: the wordmark stays level while the tablet is turned in the
screen plane. Design and usage: `rootfs/README.md`, "Idle screen (`tsv-idle-screen`)".

## Status

Running on the device and wired into the image build. Not yet confirmed by eye on the tablet
(see "To check by hand").

## Files

| File | What |
| --- | --- |
| `rootfs/scripts/idle-rotate/tsv-idle-rotate.c` | the daemon (DRM/KMS, IIO, smoothing) |
| `rootfs/scripts/idle-rotate/build.sh` | cross-build (clang + ld.lld, aarch64, glibc + libdrm sysroot) |
| `rootfs/scripts/idle-rotate/logo-524x175.bgrx.zst` | wordmark crop of the static frame, embedded at build time |
| `rootfs/scripts/render-logo.sh` | also writes the crop above; the existing outputs are unchanged (checked byte for byte) |
| `rootfs/scripts/overlay/usr/local/sbin/tsv-idle-screen` | new `run` and `stop [PID]` |
| `rootfs/scripts/overlay/etc/systemd/system/tsv-idle-screen.service` | `Type=exec`, `RemainAfterExit`, `Restart=on-failure` |
| `rootfs/scripts/overlay/etc/tsv/idle-screen.conf` | `IDLE_ROTATE=yes` |
| `rootfs/scripts/build-rootfs.sh` | builds the daemon against the image tree; checks linking and a render under qemu |

No kernel changes. The next image build includes all of this; `build-image.sh` already needs
`clang` and `ld.lld` (adbd).

## Rotation direction

`θ = atan2(a_x, −a_y)` is the tablet's clockwise turn as the viewer sees it, from the user's
calibration (upright x +0.6, y −9.5; turned clockwise x +6.4, y −3.4). The wordmark is drawn
turned by −θ: anticlockwise on the panel when the tablet is turned clockwise.

Checked:

- Rendered frames (`--render`), viewed on the laptop: at θ = +90 the wordmark runs bottom to top
  on the panel, which is level for a viewer once the panel's top edge has gone to their right
  (a 90° clockwise turn). At 180 it is upside down on the panel, at −45 turned clockwise.
- At 0 the frame is byte-identical to the static frame `idle-800x1280.xrgb8888`.
- Reference pose (tablet upright in portrait on its stand, as stated by the user): `--probe` reads
  x +0.30, y −9.54 m/s², tilt +1.8°, so the wordmark is drawn at −1.8°, essentially unrotated.
- During testing the sensor read up to x +9.25 (θ ≈ +88°) while the tablet was in landscape,
  and the daemon followed (first start at +73.8°, later +1.8°).

## Measurements (CPUs at 1.23 GHz, cpufreq not scaling yet)

| State | CPU (one core) | How |
| --- | --- | --- |
| Still | 0.5 % (31 ticks in 60 s, about 3 wakeups/s) | `/proc/PID/stat` utime+stime, service as installed |
| Turning, drawing only | 24 % (473 ticks in 20 s, 1363 frames, 60 frames/s) | `TSV_ROTATE_SPIN=60` |
| Sensor while turning | about 5 % (25 Hz × 2 reads × about 1 ms) | 100 sysfs reads in a shell: 10 ticks |
| One frame | about 4 ms | from the above |

RSS 2.6 MB.

## Findings

- The BMA253 is on a bit-banged `i2c-gpio` bus (`/sys/devices/platform/i2c-sensors`), so each
  sysfs read busy-waits about 1 ms in the kernel. The first version polled x, y and z at 10 Hz
  when still and cost 2.2 %. Now it reads x and y only, at 2 Hz when still.
- The interrupt line works: GPIO 42, `bmc150_accel_event`, 255 data-ready interrupts in 2 s at
  125 Hz with the `bma253-dev0` trigger.
- The slope ("any-motion", IIO `roc`) interrupt is armed when still, but **it has not been seen
  firing**: the tablet stayed still, and even threshold 0 gave no interrupts (most likely the
  slope engine quantises the noise below its 7.8 mg step at ±4 g). Needs a real turn to
  confirm. If it never fires, the 2 Hz poll still catches every turn, at most 0.5 s late. With
  no event fd the poll runs at 5 Hz.
- The driver refuses `roc_*_value` and `_period` while the event is enabled (EBUSY), so the
  daemon disables the events before writing them.
- An early build crashed (memset with a negative length in the span clip); `Restart=on-failure`
  restarted it as intended. Fixed and checked over 515 angles from −180° to 180°.
- The tablet hard-reset once at about 2900 s uptime while I was installing a build and starting
  a spin test: no kernel warning, no pstore record, and the binary was left as a 0-byte file (not
  yet written back). The same spin test then ran 20 s without trouble. The cause is unknown;
  installs now use `install` to a temporary name, `sync`, then `mv`.

## To check by hand

1. Upright in portrait: the wordmark is level.
2. Turn it slowly clockwise to landscape: the wordmark turns anticlockwise on the panel, smoothly,
   and stays level for you. Same anticlockwise, and to 180°.
3. Turning it briskly should start the movement at once if the motion interrupt works (check
   `grep bmc150 /proc/interrupts` before and after); otherwise it starts up to 0.5 s late.
4. Lay it flat: the wordmark keeps its last angle and does not spin.
5. No tearing while it turns.

## Left on the device

- Installed as the image would: `/usr/local/libexec/tsv-idle-rotate`, the new
  `/usr/local/sbin/tsv-idle-screen`, `tsv-idle-screen.service` and `/etc/tsv/idle-screen.conf`;
  the service is running.
- The previous versions of those three files: `/root/idle-screen-backup/`.

## Open

- Confirm the slope interrupt with a real turn; if it never fires, drop it and keep the poll.
- Drawing cost will fall once cpufreq reaches 1.8 GHz. NEON or a cached shadow buffer would cut
  it further, if needed.
- The voice app will want the accelerometer too (to rotate its own UI). It should take over the
  rotation logic from `tsv-idle-rotate` rather than read the sensor a second time.
