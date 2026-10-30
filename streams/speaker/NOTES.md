# speaker stream

TAS5782M speaker amplifier on the ThinkSmart View: mainline driver with Lenovo's DSP tuning, DT fixes, UCM2 and WirePlumber.

## Status (2026-10-30)

Ready for review. The speaker plays through PipeWire up to the stock maximum. Lenovo's tuning is written at the first stream and confirmed by register read-back on every test boot. There were no pops or idle noise above the microphone floor, and no distortion at full scale. Tested on `build-speaker` (`#3 … 21:39:52`, on top of the accepted 0001-0204). The device is back on the baseline (`#3 … 21:18:21`).

## What is where

| What | Path |
| --- | --- |
| Kernel patches (format-patch, on top of `kernel/patches/` 0001-0204) | `kernel/patches-wip/speaker/0301` binding, `0302` driver + Kconfig/Makefile/MAINTAINERS, `0303` DTS |
| Config fragment | `kernel/config/wip-speaker.config`: `CONFIG_SND_SOC_APQ8016_SBC=m` (QDSP6 machine driver; `no-unused-drivers.config` turns it off), `CONFIG_SND_SOC_TAS5782M=m` |
| Build | `streams/speaker/build-speaker.sh` (worktree `kernel/wt-speaker`, branch `ws/speaker`, build `kernel/build-speaker`) |
| Tuning firmware | `rootfs/scripts/tas5782m-dsp-fw.py` (header → `.bin`, hash-checked), `rootfs/scripts/fetch-tas5782m-tuning.sh` (download, pin, convert, manifest), called from `rootfs/scripts/build-image.sh` step 3 |
| UCM2 | `rootfs/scripts/overlay/usr/share/alsa/ucm2/conf.d/cd-18781y/cd-18781y.conf`, `…/ucm2/Lenovo/cd-18781y/HiFi.conf` |
| WirePlumber | `rootfs/scripts/overlay/etc/wireplumber/wireplumber.conf.d/51-cd-18781y-speaker.conf` |
| Test tools | `streams/speaker/tools/`: `tas5782m-verify.py` (register read-back), `capstat.py` (mic capture analysis), `session-{a,b,c,d}.sh` (locked device sessions) |
| Results | `streams/speaker/work/session-{a-run1,a,b,c,d}/` (git-ignored) |

## How the tuning is applied

- Lenovo's `tas5782m_init_sequence[]` is converted to `tas5782m_dsp_lenovo_cd-18781y.bin` (1523 `reg,val` pairs, 3046 bytes, sha256 `8122f082…a0bf`). The file drops Lenovo's preamble (the driver does the reset itself) and its final unmute (the driver owns mute). The converter asserts the file never unmutes on its own.
- The DT names it with `ti,dsp-config-name = "lenovo_cd-18781y"`, and the driver loads it at probe with `request_firmware`. No file means no probe and no sound card, so the speaker is never driven untuned.
- **Power-up order.** Probe enables PVDD (GPIO 68 regulator) and waits 120 ms, then puts the amp in standby. On the first unmute (end of prepare, with the ADSP's I2S clocks already running, as the amp's PLL needs SCLK) the driver waits 10-15 ms, then:
  1. book 0 / page 0, standby + power down, then reset, then 5 ms;
  2. writes the file while muted (CTRL3 = 0x11, DAC route off);
  3. returns to book 0 / page 0 and sets the I2S word length;
  4. writes the volume and unmutes.

  Later streams only leave standby. Stop is: mute, 25 ms (ramp), standby. Suspend turns PVDD off and the next stream rewrites the whole configuration. If writing it fails, the driver refuses to play.
- **Why a firmware file, not a table.** The coefficients belong to one product (Lenovo's speaker and enclosure, TI PPC3 output), not to the chip. A 1500-line table in a generic chip driver would tie it to one board and need a kernel change to update. Upstream already does it this way for `ti,tas5805m` (same `ti,dsp-config-name`, same file format), so review has a precedent. The data is GPL (Lenovo's GPL release), so it can be shipped (linux-firmware, or built at image time as here) without putting a blob in this repo.
- **Verified by read-back.** `tools/tas5782m-verify.py` reads back every register the file writes (1200 distinct registers, 1188 in the DSP coefficient book 0x8c, pages 0x11-0x23, plus book 0 and page 1). It ran with the stream open and the amp muted, on four boots. Each time: 1195/1200 match. The 5 that differ are expected:
  - book 0 `0x03` (mute bits clear, plus status bits 0x60/0xe0);
  - `0x2a = 0x11` (DAC route on, set by the driver);
  - `0x3d/0x3e = 0xff` (volume control at mute during the check);
  - book 0x8c page 0x23 `0x17` (the coefficient-swap flag, which clears itself).

## Test results (microphones as the sensor, mic floor about -82 dBFS)

The mic path used for measurement: `CIC1/CIC2 MUX = DMIC`, `DEC1 MUX = DMIC1`, `DEC2 MUX = DMIC2`, `MultiMedia2 Mixer TERT_MI2S_TX = 1`, `arecord -D hw:0,1 -f S16_LE -c2 -r48000`, `TX1/TX2 Digital Volume` 84 (default). Both channels work and differ by about 4 dB. The capture starts with a full-scale DMIC transient, so analysis skips the first 0.5 s.

- **Order kept: low volume first.** Session A: read-back at mute, then amp -40/-30 dB. The read-back gate passed before anything louder. Session B: -40, -30, -20, -10, 0 dB, each gated on no kernel/amp errors.
- **Level tracks the control:** 1 kHz at -20 dBFS gives -79.4 / -69.5 / -59.3 dBFS at the mic for amp -20 / -10 / 0 dB (10 dB steps). -30 and -40 are under the room/mic floor.
- **Stock maximum (amp 0 dB):** -6 dBFS and full-scale 1 kHz give -45.6 and -40.2 dBFS (+5.4 dB for +5.9 dB in, so 0.5 dB of limiting at full scale), with THD+N harmonics of 0.13 % and 0.42 % (mic included). Full-scale and -6 dBFS 40 Hz-20 kHz sweeps and -12/-20 dBFS RMS pink noise all ran. No clipping, no kernel or amp errors. Kept short (1-9 s each).
- **Pops:** three open/close cycles of silence at -30 dB and at 0 dB showed nothing above the floor (largest sample step 17 LSB). The first stream after boot, which writes the configuration, showed nothing either. PipeWire suspend/resume at 100 % showed nothing.
- **Idle noise:** stream open with silence at 0 dB is the same as standby (-82/-83 dBFS, the mic floor). PipeWire suspends after 5 s idle and the amp goes to standby (`0x02 = 0x10`, `0x76 = 0x88`).
- **First-stream latency:** about 0.6 s extra while the configuration is written (4375 ms vs 3774 ms for a 3 s file). Later streams have none.
- **S24_LE:** the same tone as S24_LE through `hw:0,0` is about 48 dB quieter than S16_LE (-107 vs -58.7 dBFS). This is a front-end (q6asm) issue, not the amp: the back end is fixed at S16_LE by `apq8016_sbc`, and 48 dB = 2^8 fits 24-bit LSB-aligned samples being read as Q31. WirePlumber pins the sink to S16LE.
- **PipeWire:** UCM HiFi gives the `Built-in Audio Speaker` sink, `alsa_output.platform-c051000.sound-card.HiFi__Speaker__sink`, S16LE / 48 kHz, mmap works (no `disable-mmap` needed). Hardware volume runs through `Speaker Amp Digital`. Map (wpctl → amp): 1.0 → 0 dB, 0.75 → -7.5, 0.5 → -18, 0.3 → -31 (first-use default), 0.25 → -36, 0.1 → -60, 0.03 → -91, 0 → mute. Mic levels at 0.3 / 0.5 / 1.0 match the map within 0.2 dB.

## Findings

- `adb reboot` sometimes does not reboot this device. The old `deploy-to-device.sh --reboot` then reported "back" on the old kernel. Now fixed in the script by the integrator. My sessions reboot with `systemctl reboot`, then check `uname -v` against the build's `UTS_VERSION` and wait for `udevadm settle` (sound modules load about 20 s after boot).
- GPIO 44 (`pdn-gpios` in the original node) is not the power-down pin. With the pad low (input, pull-down) the amp answers on I2C, and stock never drives it. Dropped. GPIO 0 (`mute-gpio`) and 45 (`fault-gpio`) are unused by stock and unbound property names; dropped too. The binding keeps optional `powerdown-gpios`/`fault-gpios`.
- Lenovo's table: 8 preamble, then 1523 configuration, then 4 unmute writes.
  - Configuration: book 0 setup (ignore SCLK errors `0x25=0x18`, PLL from SCLK `0x0d=0x10`, 48 kHz `0x22=0x03`, DSP reset), then coefficients in book 0x8c pages 0x11-0x23, ending with the swap flag.
  - Then book 0 GPIO6 output (`0x08=0x20`, `0x55=0x07`), digital volume 0 dB, and page 1 analog gain 0 dB.
  - Nothing writes the DSP volume coefficient: stock did volume in the ADSP, and its amp volume control is a stub. So stock maximum = digital 0 dB with the tuning in place, and the driver caps its control there.
- The QDSP6 back end is 48 kHz / 2 ch / S16_LE, BCLK 1.536 MHz (32 fs), I2S, codec as clock consumer. The amp's `set_fmt` is never called on the quaternary link, so the driver defaults to I2S.
- Over adb there is no logind seat, so `/dev/snd/*` has no uaccess ACL and jethac (not in `audio`) cannot open the card. WirePlumber then shows no device. The tests used a runtime `setfacl`. The image now adds jethac to `audio` (and `video`, `input`), since the device runs one app with no desktop session.
- The UCM verb is speaker-only. The mic route above works and is left for the microphone work (stock routes `DEC1 = DMIC2`, `DEC2 = DMIC1`).

## Left on the device

Nothing from this stream's userspace: UCM files, WirePlumber config, `~/.local/state/wireplumber`, test files and the firmware file were removed. Kernel side, from `deploy-to-device.sh`: `/boot/*.prev` and `/usr/lib/modules/*.prev.tar` hold the speaker kernel (`7.3.0-g97979c7a87e5-dirty`), so `--rollback` would boot it. Also stale `/boot/config-*` and `/usr/lib/modules/7.3.0-g{732aa6846ff6,97979c7a87e5}-dirty`.

## For the integrator

1. Move `kernel/patches-wip/speaker/0301-0303` into `kernel/patches/` (they apply on top of 0001-0204) and merge `kernel/config/wip-speaker.config` into `lenovo-cd-18781y.config`. The patches need the author's `Signed-off-by`. checkpatch's only other complaint is a false positive (a non-const local array that is filled and then stored as const). `dt_binding_check` was not run (no dtschema on this laptop).
2. Image: `rootfs/scripts/fetch-tas5782m-tuning.sh` is wired into `build-image.sh` step 3. It downloads Lenovo's tarball (359 MiB) into `rootfs/downloads/lenovo-gpl/`, checks size and sha256, and writes the firmware plus a manifest line. Needs `curl`, `tar`, `python3` (already required). Overlay adds the UCM2 and WirePlumber files.
3. Not done here: the q6asm S24_LE scaling (kernel, Qualcomm side), mic UCM, and EC.
