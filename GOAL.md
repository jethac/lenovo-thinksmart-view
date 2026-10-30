# GOAL

Replace LineageOS on the Lenovo ThinkSmart View CD-18781Y (serial `HUA0BMNX`) with a 64-bit mainline Linux 7.x system running Arch Linux ARM, with every piece of hardware on the device working, as a single-purpose voice appliance: speech recognition in and speech synthesis out on the device, with the chatbot's text inference on ai&'s servers.

The first thing that has to be solid is access: USB networking always works, and Wi-Fi joins `yareyare-xd-mesh` by itself at boot. Everything else is built on top of that.

## Done means

Each item is checked on the device, not inferred from logs.

### Platform

- [ ] Boots unattended from power-on to a login. No fastboot, EDL, or button presses.
- [ ] `uname -m` is `aarch64` and `uname -r` is 7.x.
- [ ] One full-screen app owns the display (no desktop environment): it shows the ai& idle screen and the conversation. The ai& Plymouth theme stays the boot splash.
- [ ] Voice in and out on the device, in English, Japanese and Mandarin: Qwen3-ASR for recognition, an on-device speech synthesiser for replies, text sent to ai&. Both models fit in RAM next to the system, with headroom.
- [ ] Survives a 24 h soak with Wi-Fi up, no kernel warnings that matter, and no memory exhaustion.
- [ ] Restoring stock from the backup is written down and has been tried at least once (on the partition table and one partition).

### Access

- [ ] Plugging into USB always gives SSH at `172.16.42.1`, from first boot onward, whatever state Wi-Fi is in.
- [ ] Joins `yareyare-xd-mesh` at boot and reconnects after a router restart and after GTK rekeys.
- [ ] Accepts SSH as user `jethac`, by password (the user's chosen password, kept out of this repo) and by the laptop's key, from first boot over USB and Wi-Fi.
- [ ] Reachable over SSH on the LAN and on the tailnet.
- [ ] `adb shell`, `adb push`/`pull` and `adb reboot` work over USB from the laptop, with adb key authentication, alongside USB networking and the serial gadget.

### Hardware

| Hardware | Part | Done when |
| --- | --- | --- |
| Display | DSI panel `boyift8201_800p_video` | Native 800x1280, correct rotation, no tearing |
| Backlight | PMI8950 WLED | Full range, survives blank and unblank |
| Touch | FocalTech FT8201 (TDDI, `fts_ts` at i2c 3-0038 on stock). Other units ship Himax HX83100A | All points, wakes the screen |
| GPU | Adreno 506 (freedreno) | Hardware GL/GLES for the full-screen app (DRM/KMS). **No Vulkan**: Mesa's Turnip starts at a6xx and lists no plans for a5xx; freedreno covers a5xx for GL. |
| Video decode | Venus | H.264 and HEVC decode through V4L2 |
| Wi-Fi | QCA9379 SDIO (`ath10k_sdio`) | As in Access above |
| Bluetooth | QCA UART | Pairs, A2DP audio out |
| Speaker | TI TAS5782M (10 W) | Clean playback at full volume through PipeWire |
| Microphones | Dual DMIC array | Both channels capture; usable for wake word and ASR |
| Echo cancellation | PipeWire / WebRTC AEC | Mic stays usable while the speaker plays |
| Camera | Samsung S5KC505A on CAMSS | Live preview and stills through libcamera |
| Camera privacy shutter | Switch | State is readable and the camera respects it |
| Mic mute switch | Switch | State is readable and capture is muted in hardware or by policy |
| Buttons | Power, Volume +/- | Input events; volume keys wake the screen |
| Proximity / light | Vishay VCNL4200 | Wakes the screen; ambient light drives brightness. IR LED never left on at full power |
| Accelerometer | Bosch BMA253 | Auto-rotation |
| Thermal, cpufreq | MSM8953 | Scales to 1.8 GHz and throttles rather than crashes |
| Suspend / screen off | | Screen off and on without restarting the compositor |

## Not in scope

- Android, and anything only Android does.
- Battery and charging (the device has none and runs off the barrel jack).
- Any desktop environment or multi-app setup (Omarchy, Plasma, Hyprland): 2 GB of RAM is reserved for the speech models and the one app.
- The voice assistant itself. The microphones, echo cancellation and speaker are in scope. The speech recognition and assistant software that sits on them is the next project.

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
| Camera | `ubuntu-thinksmart/research/camera/` (S5KC505A reverse notes and driver plan) |

## Recovery

- Full backup of the stock device: `synology-nas:/volume1/NetBackup/ThinkSmart_View-HUA0BMNX-before-omarchy-20261029/`. Every partition except `userdata` as a zstd image with on-device SHA-256, both GPT copies, `stock_layout.sfdisk`, and `/data` as a tar.
- Never overwrite: `persist`, `modemst1`, `modemst2`, `fsg`, `devinfo`, `sbl1`, `rpm`, `tz`, `aboot` and their `*bak` copies. If the partition table changes, `persist` is restored into the new `persist` before first boot.
- Back to stock: write `gpt_primary.bin` and `gpt_backup.bin` (or `stock_layout.sfdisk`), then the partition images, through EDL.

## Milestones

1. Backup complete and verified on the NAS.
2. EDL read-only check: `printgpt`, read one partition, compare its hash with the backup. Confirms the side USB-C port carries data.
3. Known-good boot: lk2nd plus an existing image, to prove the boot chain on this unit.
4. Our kernel: `barni2000/7.3/develop` built here, booting through lk2nd.
5. Arch Linux ARM root filesystem, with USB networking on first boot.
6. Wi-Fi, with the rekey problem checked on 7.3 and the patch carried forward if it is still needed.
7. Stage B repartition (root grows to about 6.7 GiB, for the models), then the voice pipeline: recognition, synthesis, the ai& client, and the full-screen app.
8. Hardware, roughly easiest first: buttons, sensors, backlight, touch, GPU, video decode, Bluetooth, speaker, microphones, echo cancellation, camera.
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

## Open questions

- Does the side USB-C port carry data in EDL on this unit?
- Which speech synthesiser covers English, Japanese and Mandarin at usable speed on the A53 cores, and how much RAM do recognition and synthesis need together?
- Is the `ath10k` rekey patch still needed on 7.3?
- Which msm8953 patches on `7.1.3/main` (381 commits not on the 7.3 branch) are genuinely missing from `barni2000/7.3/develop`, and do any matter for this device?
- Is CAMSS for MSM8953 far enough along upstream for the S5KC505A, or does the camera need CAMSS work as well as a sensor driver?
- Do the camera shutter and mic mute switches show up as GPIOs, and are they wired to cut power or only report state?
- Should fixes made here go upstream to msm8953-mainline and to `rickx/ubuntu-thinksmart`?
