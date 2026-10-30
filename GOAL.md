# GOAL

Replace LineageOS on the Lenovo ThinkSmart View CD-18781Y (serial `HUA0BMNX`) with a 64-bit mainline Linux 7.x system running Arch Linux ARM, with every piece of hardware on the device working, as a single-purpose voice appliance: speech recognition in and speech synthesis out on the device, with the chatbot's text inference on ai&'s servers.

The first thing that has to be solid is access: USB networking always works, and Wi-Fi joins `yareyare-xd-mesh` by itself at boot. Everything else is built on top of that.

## Done means

Each item is checked on the device, not inferred from logs. `[x]` means verified on `HUA0BMNX`; notes say what is still missing. Last reviewed 2026-10-30.

### Platform

- [x] Boots unattended from power-on to a login. No fastboot, EDL, or button presses. (Lenovo logo, lk2nd, ai& splash, about 15 s to USB networking.)
- [x] `uname -m` is `aarch64` and `uname -r` is 7.x. (`7.3.0`, msm8953-mainline `barni2000/7.3/develop` plus `kernel/patches/`.)
- [ ] One full-screen app owns the display (no desktop environment): it shows the ai& idle screen and the conversation. The ai& Plymouth theme stays the boot splash. (Splash and the accelerometer-levelled idle screen work; the conversation app does not exist yet.)
- [ ] Voice in and out on the device, in English, Japanese and Mandarin: Qwen3-ASR for recognition, an on-device speech synthesiser for replies, text sent to ai&. Both models fit in RAM next to the system, with headroom. (Qwen3-ASR Q4_K_M with a Q8_0 conv stem runs at 1.3-1.6x real time: a 2.5 s English command takes 4.0 s, peak about 1 GB; synthesis not chosen yet; see `streams/asr/NOTES.md`.)
- [ ] Survives a 24 h soak with Wi-Fi up, no kernel warnings that matter, and no memory exhaustion.
- [ ] Restoring stock from the backup is written down and has been tried at least once (on the partition table and one partition). (Partition table: stock GPT rolled back and re-applied from the running system during stage B, both verified byte for byte; restoring a partition image not yet tried.)

### Access

- [x] Plugging into USB always gives SSH at `172.16.42.1`, from first boot onward, whatever state Wi-Fi is in. (From a USB-A host; see Decisions.)
- [ ] Joins `yareyare-xd-mesh` at boot and reconnects after a router restart and after GTK rekeys. (Everything but the join is in place: JP regulatory, permanent MAC, NTP, rekey fix `0101`; waiting on the PSK. Test list in `streams/wifi/NOTES.md`.)
- [ ] Accepts SSH as user `jethac`, by password (the user's chosen password, kept out of this repo) and by the laptop's key, from first boot over USB and Wi-Fi. (Key login over USB verified; password login and Wi-Fi not yet tested.)
- [ ] Reachable over SSH on the LAN and on the tailnet.
- [ ] `adb shell`, `adb push`/`pull` and `adb reboot` work over USB from the laptop, with adb key authentication, alongside USB networking and the serial gadget. (`shell`, `push`, `pull` and key auth work, root shell. **`adb reboot` does not reliably reboot**: use `adb shell systemctl reboot`; to fix.)

### Hardware

| Hardware | Part | Done when | State (2026-10-30) |
| --- | --- | --- | --- |
| Display | DSI panel `boyift8201_800p_video` | Native 800x1280, correct rotation, no tearing | working: 800x1280@60 over DRM/KMS; panel rails held on in DT until the driver handles them |
| Backlight | PMI8950 WLED | Full range, survives blank and unblank | working; low-end cutoff not settled (floor 1400 of 4095 for now) |
| Touch | FocalTech FT8201 (TDDI, `fts_ts` at i2c 3-0038 on stock). Other units ship Himax HX83100A | All points, wakes the screen | driver binds (`edt-ft5x06`); input not yet tested |
| GPU | Adreno 506 (freedreno) | Hardware GL/GLES for the full-screen app (DRM/KMS). **No Vulkan**: Mesa's Turnip starts at a6xx and lists no plans for a5xx; freedreno covers a5xx for GL. | kernel side up (zap shader, microcode); Mesa being installed and benchmarked (`streams/gpu-compute/`) |
| Video decode | Venus | H.264 and HEVC decode through V4L2 | not enabled yet |
| Wi-Fi | QCA9379 SDIO (`ath10k_sdio`) | As in Access above | probes, scans the mesh; join waits on the PSK |
| Bluetooth | QCA UART | Pairs, A2DP audio out | not tested on mainline |
| Speaker | TI TAS5782M (10 W) | Clean playback at full volume through PipeWire | **done**: driver `0301`-`0303`, Lenovo tuning verified by register read-back, 0.13 % THD at -6 dBFS, no pops |
| Microphones | Dual DMIC array | Both channels capture; usable for wake word and ASR | capture works (used to measure the speaker); UCM profile not written |
| Echo cancellation | PipeWire / WebRTC AEC | Mic stays usable while the speaker plays | not started |
| Camera | Samsung S5KC505A on CAMSS | Live preview and stills through libcamera | raw frames captured in three modes (driver `0401`-`0403`, sensor at I2C `0x37`); libcamera not started |
| Camera privacy shutter | Switch | State is readable and the camera respects it | reads open; closed state not yet checked by hand |
| Mic mute switch | Switch | State is readable and capture is muted in hardware or by policy | **not fitted on this unit** (measured: the only switch is the lens cover, and it does not mute the mics) |
| Buttons | Power, Volume +/- | Input events; volume keys wake the screen | volume keys present; **no power button on this unit**; events not yet tested by hand |
| Proximity / light | Vishay VCNL4200 | Wakes the screen; ambient light drives brightness. IR LED never left on at full power | disabled on purpose until the driver can limit the IR LED |
| Accelerometer | Bosch BMA253 | Auto-rotation | working: the idle screen keeps the logo level |
| Thermal, cpufreq | MSM8953 | Scales to 1.8 GHz and throttles rather than crashes | **done**: 652.8-1804.8 MHz (speed bin 6), two-stage thermal policy `0204`, 10 min all-core at 61.6 °C |
| Suspend / screen off | | Screen off and on without restarting the compositor | not started |

## Not in scope

- Android, and anything only Android does.
- Battery and charging (the device has none and runs off the barrel jack).
- Any desktop environment or multi-app setup (Omarchy, Plasma, Hyprland): 2 GB of RAM is reserved for the speech models and the one app.
- The chatbot's language model itself: text inference runs on ai&'s servers.

## Constraints

- The bootloader is locked (`devinfo` unlock flags are 0). Partitions can only be written through Qualcomm EDL (`bkerler/edl`). fastboot flashing does not work.
- Boot chain: Lenovo `aboot`, then lk2nd in `boot`, then the kernel and DTB from `/boot/extlinux/extlinux.conf`.
- 7.3 GB eMMC and 2 GB RAM. Every package earns its place.
- Firmware blobs come from this device's own partitions (`modem`, `dsp`, `persist`), not downloaded from somewhere else.
- The USB-C data port is behind the plug on the right side (portrait, camera top left). Power is the barrel jack.

## Base and sources

| What | Where |
| --- | --- |
| Kernel | `msm8953-mainline/linux`, branch `barni2000/7.3/develop` (Linux 7.3, has `apq8053-lenovo-cd-18781y.dts`). Built by `kernel/build.sh` with `kernel/config/lenovo-cd-18781y.config`. |
| Device fixes | `jethac/ubuntu-thinksmart` (fork of justhalfbit, source rickx): TAS5782M driver, `ath10k_core` rekey patch, DTS patch, UCM2, WirePlumber policy, sensor and wake daemons. Reference for what already works on 6.19.5. |
| Userland | Arch Linux ARM aarch64 |
| Flashing | `bkerler/edl`, in `tools/edl` |
| Camera | `streams/camera/` (decoded S5KC505A tables, driver); `ubuntu-thinksmart/research/camera/` for the earlier notes |
| Hardware library | `jethac/thinksmart-view-hal` (`view-hal`, sibling of `thinksmart-hub-hal`) |
| Bootloader | `msm8916-mainline/lk2nd` (target `lk2nd-msm8953`), built by `lk2nd/build.sh` |
| Workstreams | `WORKSTREAMS.md` (device lock, kernel deploy and rollback, per-stream patch series) |

## Recovery

- Full backup of the stock device: `synology-nas:/volume1/NetBackup/ThinkSmart_View-HUA0BMNX-before-omarchy-20261029/`. Every partition except `userdata` as a zstd image with on-device SHA-256, both GPT copies and `stock_layout.sfdisk`. `/data` (the previous owner's) is only partly backed up: the tar was stopped to free the adb link.
- Never overwrite: `persist`, `modemst1`, `modemst2`, `fsg`, `devinfo`, `sbl1`, `rpm`, `tz`, `aboot` and their `*bak` copies. If the partition table changes, `persist` is restored into the new `persist` before first boot.
- Back to stock: write `gpt_primary.bin` and `gpt_backup.bin` (or `stock_layout.sfdisk`), then the partition images, through EDL.

## Milestones

1. **Done.** Backup complete and verified on the NAS.
2. **Done.** EDL read-only check: `printgpt`, read one partition, compare its hash with the backup. Confirms the side USB-C port carries data.
3. **Done** (with our own lk2nd and image). Known-good boot: lk2nd plus an existing image, to prove the boot chain on this unit.
4. **Done.** Our kernel: `barni2000/7.3/develop` built here, booting through lk2nd.
5. **Done.** Arch Linux ARM root filesystem, with USB networking on first boot.
6. **In progress.** Wi-Fi, with the rekey problem checked on 7.3 and the patch carried forward if it is still needed. (Still needed; `0101` accepted; join waits on the PSK.)
7. **Repartition done 2026-10-31** (root 6.6 GiB, 5.3 GiB free; `streams/stage-b/`); voice pipeline in progress. Stage B repartition (root grows to about 6.7 GiB, for the models), then the voice pipeline: recognition, synthesis, the ai& client, and the full-screen app.
8. **In progress** (see the table). Hardware, roughly easiest first: buttons, sensors, backlight, touch, GPU, video decode, Bluetooth, speaker, microphones, echo cancellation, camera.
9. 24 h soak and the recovery drill.

## Decisions

- 2026-10-30: USB requirement for now is device mode into any VBUS-providing host (hub or USB-A port); the port has no CC termination (measured on boot: `CC-line-state=2` = OPEN with a cable attached), so a CC-waiting Type-C host is not guaranteed. Host/OTG mode and the CC measurement are deferred until after first mainline boot.
- 2026-10-30: GPU goal is GL/GLES only. Mesa's Turnip starts at a6xx and lists no plans for a5xx; freedreno still covers a5xx for GL, so hardware GL for the full-screen app is the achievable line and Vulkan is out of scope unless someone brings a5xx up.
- 2026-10-29: Arch Linux ARM and Omarchy, not postmarketOS or the rickx Ubuntu image. The user wants the same tooling as the laptop.
- 2026-10-30: Omarchy dropped. The device becomes a single-purpose voice appliance: Qwen3-ASR and an on-device speech synthesiser need most of the 2 GB of RAM, so a desktop running several apps does not fit.
- 2026-10-29: Kernel base was going to be `msm8953-mainline` `7.1.3/main` (newest `/main` branch with this device's DTS).
- 2026-10-30: Switched to `barni2000/7.3/develop` (Linux 7.3). 7.1 is end of life upstream; current releases are 7.3 and 7.2.13. The device DTS differs between them only in pinctrl naming and touch interrupt style, and `msm8953.config` is unchanged.
- 2026-10-29: Large files and backups go to `synology-nas` under `NetBackup`.
- 2026-10-29: Scope is full device support, camera, speaker and microphones included.
- 2026-10-30: Thermal policy: cap at 1420.8 MHz from 75 °C, full range from 85 °C, critical at 100 °C, plus a GPU trip at 80 °C (`0204`). Stock had no thermal-engine policy to copy.
- 2026-10-30: Speaker tuning is a firmware file built from Lenovo's GPL `tas5782m.h` at image build time; the driver refuses to play without it, and its volume is capped at 0 dB (stock maximum).
- 2026-10-30: Regulatory domain JP comes from a service when the Wi-Fi phy registers, not a cfg80211 module option (which ath10k's US hint overrides).
- 2026-10-30: `kernel/build.sh` resets the tree and applies the whole patch series on every build (overlapping patches had been applied twice); `deploy-to-device.sh` confirms a reboot by boot ID (`adb reboot` does not always reboot).
- 2026-10-31: Stage B done: GPT now has 29 partitions (p1-p23 unchanged, `system` 6.80 GiB, `persist`/`syscfg`/`mcfg`/`apdp`/`msadp` moved to the end, 22 Android partitions dropped). aboot and lk2nd boot it. Root grown online to 6.6 GiB.
- 2026-10-31: Wake word is "Hey Straylight", after the household system the Hub 500 panels belong to. Chosen over anything built on "AI" (constant false triggers in English and Japanese speech) and over a coined name. To verify on the device: recall per language and false triggers per hour on English, Japanese and Mandarin speech.
- 2026-10-30: Repositories are public: `jethac/lenovo-thinksmart-view` and `jethac/thinksmart-view-hal`. No firmware, device captures or secrets in them.

## Open questions

- Which speech synthesiser covers English, Japanese and Mandarin at usable speed on the A53 cores, and how much RAM do recognition and synthesis need together?
- How far can Qwen3-ASR latency fall on the CPU: conv stem during speech, speculative decoding, a shorter prompt, a lighter output head? (`streams/asr/NOTES.md`)
- Which msm8953 patches on `7.1.3/main` (381 commits not on the 7.3 branch) are genuinely missing from `barni2000/7.3/develop`, and do any matter for this device?
- Does the lens cover cut power to the camera, or only report its state? Does closed read as 1?
- Should fixes made here go upstream (msm8953-mainline, ath10k, ASoC, media) and to `rickx/ubuntu-thinksmart`?

Answered:
- The side USB-C port carries data in EDL, from a USB-A host (EDL, `printgpt`, read-back and both writes done over it).
- The `ath10k` rekey patch is still needed on 7.3: no upstream fix (`0101`).
- CAMSS for MSM8953 is enough for the S5KC505A: raw frames captured with only a sensor driver and board nodes.
- The Adreno 506 does not help Qwen3-ASR: about 14 GFLOP/s FP32 in OpenGL ES 3.1 compute, half the CPU Q8_0 rate; no OpenCL, no Vulkan (`streams/gpu-compute/NOTES.md`).
- Switches: the lens cover is GPIO 87 (`SW_CAMERA_LENS_COVER`); the mic mute switch is not fitted on this unit.
