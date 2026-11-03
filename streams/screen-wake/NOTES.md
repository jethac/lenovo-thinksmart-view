# screen-wake

The screen behaves like an appliance's: it blanks after idle and wakes on touch, a key, the
camera cover, motion, approach and the wake word. It stays on through a conversation, takes
its brightness from the ambient light, and dims during quiet hours. The policy is in the
Straylight app (`straylight-voice`, `src/screen.rs`), the hardware in view-hal (`light`,
`touch`), and the VCNL4200 IR LED is made safe in the kernel (patch 0601).

## Status (2026-11-03)

Working on the tablet and tested there, except for the physical tests listed under "To check
by hand" (a real finger, moving the tablet, a hand near the sensor, room light).

| Test | How | Result |
| --- | --- | --- |
| Off after idle | test config `idle = 25`, `dim = 5` | dimmed at 20 s, off at 25 s, repeatedly |
| Off is dark | PMI8950 WLED `MOD_EN` (`0xd846`, debugfs regmap) | `0x80` on, `0x00` with `bl_power` 4; DPMS stays On; no WLED fault IRQs |
| Wake on touch | `input_event` records written into the touchscreen's evdev node (the kernel injects them to every reader, libinput included), on the settings button | off: wakes in 0.48-0.57 ms, **settings not opened** (shield); on: the same tap opens settings |
| Wake on a key | KEY_VOLUMEUP injected into `gpio-keys` | wakes in 0.8 ms, volume unchanged |
| Wake word, hold | `{"state":"listening"}` (what the listener sends on the wake word) | wakes in 0.54 ms; held on 35 s past the 25 s idle; off 15 s (`after_conversation`) after Idle |
| No false wakes | off for several 20 s periods, motion and proximity sampled | none |
| Late touchscreen | a boot where the FT8201 probed after the app | found: the reader looks again every 2 s (fixed after this boot) |
| No light sensor | baseline kernel after another stream's reboot | starts at the fixed 2000; blanking and touch/keys/conversation wake work |
| ALS | dark evening room | 2-4 counts at 100 ms (0.024-0.05 lx), level 1600 (`auto_min`) |
| Panel leak into ALS | backlight 1400 / 4095 / off | 0-4, 2-4, 2-6 counts: no leak, so no feedback loop |
| CPU while off | `/proc/PID/stat` over 20 s | 21-23 ticks of 2000 (about 1.1 % of a core, sensors included); Idle on is 4.7 % |
| DT-probed sensor | stream kernel booted once (`build-screen-wake`) | `vcnl4000` autoloads, `vdd` L10 and `vio` L6 are real consumers, IRQ 43 registered (0 counts), udev rule applied, app OK |

## The IR LED: setting and reasoning

**Setting:** LED_I 50 mA (the lowest), 1 pulse (MPS 1), PS_IT 4T (384 us by the driver's
table), active force mode. One measurement per read, two reads a second, **only while the
backlight is off**, plus a confirming second read when something looks near. With the screen
on, nothing reads proximity, so the LED is dark. That is LED on-time about 1/1300 while off and
zero while on. The previous port ran 200 mA at 9T in normal mode at a 1/1280 duty, all the
time the screen was off. Upstream runs 8 pulses at 120 mA at a 1/160 duty whenever the chip is
powered, which includes every ambient light read: about 1/20 on-time.

**LED_I does not set the LED current on this board.** Measured over i2c-dev with the node
disabled (no driver), active force mode, nothing in front:

| PS_IT | Pulses | LED_I 50 mA | 120 mA | 200 mA |
| --- | --- | --- | --- | --- |
| 9T | 1 | 1-3 | 2-3 | 1-3 |
| 9T | 8 | 18-23 | 18-21 | 17-21 |

The counts scale with pulses and with integration time, not with LED_I. The VCNL4200 drives
its IRED through an external PMOS FET whose source resistor sets the current (datasheet
Fig. 11, Vishay doc 84430 rev 1.8): LED_I is only the gate drive, and the datasheet says
"LED_I programmed to lowest value of 50 mA is enough to drive the FET". So the light emitted
is set by pulse width x pulses x reads, and those are what were chosen low. The board's actual
IRED current is unknown: it needs the RLED value from the schematic, or a current probe.

**Fail-safe is in the chip and the driver, not in a loop.** In active force mode the chip
measures once per PS_TRIG write and the LED is otherwise dark. If the app dies, nothing
triggers, so the LED stays off. The driver also autosuspends (PS_SD, ALS_SD) 2 s after the last
read. Checked with the patched driver: three seconds of ambient light reads (chip powered,
PS_SD clear) left a stale 8-pulse value in PS_DATA, so no normal-mode cycle ran. After wake,
PS_CONF1 shows SD set within 3 s. If the driver measured continuously (upstream), view-hal's
`light::open` would refuse the sensor: at 1T an upstream read returns in under 8 ms, a
triggered one takes 20 ms or more, and the fastest of three is compared with 15 ms.

**Conversion time** in active force mode: data is in PS_DATA 9-10 ms after PS_TRIG, the same
at 1T, 4T and 9T and at duty 1/160 and 1/1280 (read back in one `i2ctransfer`, about 1 ms per
read on the bit-banged bus). The driver waits 20 ms.

**Detection range: not measured** (needs a hand). Nothing in front reads 0-1 counts at 4T and
1 pulse on this unit. The previous port saw 87-1044 for a hand at 9T on its unit, and 30-80 for
a hand at about 30 cm. Scaled to 4T (x4/9) that is 39-464, and 13-36 at 30 cm. The threshold
is 15 counts over a baseline that follows the room, confirmed by a second read, so a hand
should register out to roughly 20-30 cm. Raise `proximity_threshold` if it wakes on passers-by.
Lower it, or set PS_IT 8T (twice the light per read), if it needs a closer approach than wanted.

## Blank method

`bl_power` 4 (view-hal `Display::set_power(false)`): the WLED driver sees brightness 0 and
clears the module enable, so the panel is dark. The DSI panel and its TDDI touch controller
keep running, so touch can wake it. Writing brightness 0 does the same in the WLED driver; the
earlier port's trouble with 0 was KWin reacting to it, and there is no compositor here.
DPMS/modeset was not used: it would power the TDDI down, and with it touch. Wake: the level is
written while still off, then `bl_power` 0; the app measures 0.5-0.8 ms for the two writes, and
the `bl_power` write alone took 5.6 ms from a shell. The floor stays 1400.

## The design (app)

`straylight-voice` `src/screen.rs` (details in the app README, "The screen"):

- Conversation: the app's own state machine. Any state but Idle and Offline wakes and holds
  the screen, so the listener's `listening` on the wake word is the wake, with no hint file
  and no protocol change. Settings' sign-in, WPS and keyboard pages hold it too.
- Touch: view-hal `touch` reads BTN_TOUCH beside libinput. While off, a full-screen
  `TouchArea` (`shield`) takes every touch until the waking finger lifts, plus 150 ms.
- Motion: view-hal `orientation`, twice a second while off. Wake on 0.5 m/s² on any axis
  between samples (noise is about 0.06), or 1.5 m/s² from where it was left (a slow tilt). The
  previous port's threshold was 40 counts at 0.019 m/s² per count, 0.77 m/s².
- Brightness: lux every 5 s while on, smoothed by half a step per reading. The level is
  `auto_min` 1600 in the dark to 4095 at 300 lx, `1600 + 2495 * log10(1+lx)/log10(301)`.
  Changes are faded at 800 levels/s, with a 120 deadband (the two ends always reached).
  Quiet hours 22:00-07:00 cap the level at 1450. A user level comes from
  `{"screen":{"brightness":0..100}}` or `--brightness N`.
- Settings: `/etc/straylight-screen.conf`; at run time `{"screen":{"wake"|"blank"|"brightness"|"idle"}}`
  and `{"get":"screen"}` (status, including the last wakes with their latency).
- Exit: backlight on at the awake level.

Not used: the BMA253 any-motion interrupt (never seen firing, `streams/idle-rotate`) and VCNL
threshold interrupts (they need normal mode). Polling twice a second only while off costs
about 1 % of a core.

## Branches and files

| Where | What |
| --- | --- |
| `straylight-voice`, branch `screen-wake` (worktree `../straylight-voice-screen`), commit `07cbde9` | `src/screen.rs`, hooks in `controller.rs`, `charms.rs`, `state.rs`, `main.rs`, `hw.rs`, `ui/app.slint` (`asleep`, `shield`), README. Not pushed. The worktree's `Cargo.toml` points at `../thinksmart-view-hal-screen` (local edit, **not committed**); after view-hal's branch is merged the committed path is right as it is. |
| `thinksmart-view-hal`, branch `screen-wake` (worktree `../thinksmart-view-hal-screen`), commit `ffc9d61` | `src/light.rs` (VCNL4200: settings, lux, proximity, the on-demand check), `src/touch.rs`, `display.rs` docs (bl_power verified), `STATE.md`. Not pushed. |
| `kernel/patches-wip/screen-wake/0601-…active-force-mode.patch` | the driver change |
| `kernel/patches-wip/screen-wake/0602-…enable-the-vcnl4200.patch` | enables the node; renames `vddio-supply` to `vio-supply` (see below) |
| `kernel/config/wip-screen-wake.config` | `CONFIG_VCNL4000=m` (for the integrator to fold into `lenovo-cd-18781y.config`) |
| `kernel/build-screen-wake/`, `kernel/wt-screen-wake/` | the stream's build (`streams/screen-wake/work/build-kernel.sh`: `build.sh` plus the fragment) |
| `rootfs/scripts/overlay/etc/udev/rules.d/70-tsv-vcnl4200.rules` | writes 1 pulse, 50 mA, 4T, ALS 100 ms when the IIO device appears |
| `rootfs/scripts/overlay/etc/straylight-screen.conf` | the defaults, documented |
| `streams/screen-wake/work/` | probe and test scripts, the injected-touch event files |

For the image: `rootfs/scripts/straylight/pins.sh` needs `STRAYLIGHT_COMMIT` and
`VIEW_HAL_COMMIT` moved once these branches are merged and pushed (and `--repin`). The kernel
needs 0601, 0602 and the config line. Nothing else in `build-rootfs.sh` changes: the overlay
files are copied as they are.

## Findings for other documents

- **Baseline DT supply name.** `kernel/patches/0002` gives the sensor `vddio-supply`, but the
  `vishay,vcnl4000` binding and driver use `vio-supply`, so the driver would take a dummy
  regulator for it. 0602 renames it. With `vio`, the regulator summary shows `0-0051-vio`
  on L6 and `0-0051-vdd` on L10.
- **`devices/proximity-light/ANALYSIS.md` §4 decodes `PS_CONF1 = 0xCA` with VCNL4040 fields.**
  On the VCNL4200 it is PS_DUTY 11 = **1/1280**, PERS 00, PS_IT 101 = **9T**, SD 0 (the
  VCNL4200's duty steps are 1/160-1/1280, not 1/40-1/320). The "200 mA" there is LED_I, which
  does not set the current on this board (above).
- Upstream init writes 8 pulses at 120 mA. In active force mode those light nothing until a
  read, and the udev rule and view-hal replace them before the first one.

## Left on the device

- **Baseline kernel** (the stream kernel was booted once for the DT test and the baseline put
  back with `kernel/deploy-to-device.sh --reboot`).
- `/usr/local/bin/straylight-voice` and `straylight-voicectl` from the `screen-wake` branch
  (the screen blanks after 5 minutes idle). The previous pair is in `/root/screen-wake-backup/`.
  To undo: copy them back and `systemctl restart straylight-voice`.
- The patched `vcnl4000.ko` loaded by hand (`/root/vcnl4000.ko`, 0601 built out of tree against `build-7.3` (`make -C kernel/build-7.3 ARCH=arm64 LLVM=1 M=<dir with vcnl4000.c and obj-m> modules`)),
  with the sensor instantiated through `i2c-0/new_device`, so ALS and proximity work on the
  baseline kernel until the next reboot. After a reboot the app runs without the sensor (fixed
  level 2000). To undo now: `systemctl stop straylight-voice; echo 0x51 >
  /sys/bus/i2c/devices/i2c-0/delete_device; rmmod vcnl4000; systemctl start straylight-voice`.
- `/etc/udev/rules.d/70-tsv-vcnl4200.rules` (as in the overlay; acts only on the sensor).
- No `/etc/straylight-screen.conf` (defaults). `/root/*.sh`, `/root/*.bin`: test scripts.

## To check by hand

1. **Touch:** wait 5 minutes (or `straylight-voicectl '{"screen":{"blank":true}}'`). Tap the
   settings button: the screen comes on and settings does **not** open. Tap again: it opens.
2. **Motion:** blank it, then pick the tablet up or nudge it: it comes on within about 0.5 s.
   Leave it blank on the desk for an hour: it must not wake by itself (check
   `straylight-voicectl '{"get":"screen"}'`, `wakes`).
3. **Approach:** blank it, then bring a hand towards the top edge (the sensor is next to the
   camera): note the distance at which it wakes. `journalctl -u straylight-voice | grep
   proximity` shows the two counts and the baseline. A phone camera pointed at the sensor shows
   the IR flashes: twice a second while blanked, never while on.
4. **Wake word:** blank it, say "Hey Straylight": it comes on with Listening and stays on until
   two minutes after the reply.
5. **Light:** with the room lights on, then off, then daylight, compare `lux` and `level` in
   `{"get":"screen"}`, and whether the level looks right. Tune `auto_min`, `auto_max` and
   `auto_lux`. The dark-room level, 1600, was not judged by eye.
6. **Quiet hours:** after 22:00 the level drops to 1450 (`"quiet":true`).
