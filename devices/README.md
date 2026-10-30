# Device analysis

One directory per piece of hardware on the ThinkSmart View CD-18781Y (serial `HUA0BMNX`). Each directory has a `BRIEF.md` that says what to find out about that device. The findings go next to it.

Read [`../GOAL.md`](../GOAL.md) first. The analyses were written while the plan still included Omarchy (Hyprland). That plan was dropped on 2026-10-30; where an analysis says Hyprland or the desktop, read it as the single full-screen app. It defines what "working" means for each device and what is out of scope.

## What "stock" means on this unit

The unit was bought second-hand, already modified. What is on it is **not** Lenovo's shipping software:

- Kernel: a community 3.18 build (`3.18.71-perf-gac629079-dirty`, built 2024-06-02) from Lenovo's GPL source, inside an unofficial LineageOS 15.1 (`lineage_starfire`, builder `deadman`).
- `/vendor`, `/firmware` (`modem`), `/dsp`, `/persist`: Lenovo's (`ro.vendor.build.fingerprint` is the Lenovo CD-18781Y 8.1.0 build).
- `/data`: the previous owner's apps (Termux, `com.hoe.hoge`, and others). Not ours, and not hardware evidence. Do not read through it beyond what a brief needs.

So the running kernel's view of the hardware (device tree, probe logs, sysfs) is good evidence of how the board is wired. Userspace configuration may have been changed by the previous owner. When a fact matters, check it against Lenovo's GPL source or the vendor partition. In these briefs, "stock" means the as-received system.

## What an analysis produces

In its device directory:

- `ANALYSIS.md`: the findings, in the structure below.
- `evidence/`: raw material the findings rest on (command output, register dumps, DT fragments, log excerpts, datasheet page references). Name files so the source and date are obvious, for example `stock-dmesg-2026-10-30.txt`.

`ANALYSIS.md` sections, in this order:

1. **Summary.** Three to six lines: what the part is, its state on mainline 7.3, and the single biggest blocker.
2. **Identity.** Exact part number and how you know it (marking, ID register, stock driver probe log, DT). Note when this unit differs from what other ports document.
3. **Wiring.** Bus, address, GPIOs, interrupts, regulators, clocks, resets, pinctrl. For each, the stock value and the mainline value, side by side, and whether they agree.
4. **Stock behaviour.** How the Lenovo Android kernel and userspace drive it: driver, firmware files, init sequence, tuning values, power sequencing.
5. **Mainline state.** What 7.3 has: driver, DT node, bindings, firmware path. What is missing or wrong.
6. **Gap and plan.** Concrete work to reach the "done" line in `GOAL.md`, as ordered steps, each with how it will be tested on the device.
7. **Risks.** Anything that can damage hardware, lose calibration data, or brick the boot.
8. **Open questions.** What you could not settle, and what evidence would settle it.
9. **Sources.** Every file, URL, commit and command used.

Separate what you observed from what you inferred. Mark inferences as such.

## Where to look

| Source | Location |
| --- | --- |
| Live stock device (LineageOS 15.1, kernel 3.18, root over adb) | `adb -s 192.168.1.176:5555` (run `adb root` first if `id` is not root) |
| Stock device tree, flattened | `/proc/device-tree` on the device, or `../stock/` once captured |
| Stock partitions (incl. `modem`, `dsp`, `persist` firmware and calibration) | `../backup-20261029/partitions/*.img.zst`, mirrored on `synology-nas:/volume1/NetBackup/ThinkSmart_View-HUA0BMNX-before-omarchy-20261029/` |
| Lenovo GPL kernel source for this device | `https://download.lenovo.com/consumer/mobiles/lenovo_cd-18781y_cd-18781y.201218.2018_opensource.tgz` |
| Mainline kernel, 7.3 | `../kernel/linux-7.3` (msm8953-mainline `barni2000/7.3/develop`). The older `../kernel/linux` (`7.1.3/main`) is kept for comparison; device DTS is `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` |
| Older community main branch | msm8953-mainline `7.1.3/main`, in `../kernel/linux` |
| Lenovo official firmware (EDL packages, firehose, rawprogram) | `../official-firmware/` (210602.2103 Zoom is latest; 210228.109 Teams). Unpacked images are a clean reference for `vendor`, `modem`, `dsp` and the stock kernel. Read `../official-firmware/README.md` first: the package includes a RAM dump from another unit that is not evidence. |
| Prior port (Ubuntu, 6.19.5) | `../ubuntu-thinksmart/` (`README.md`, `research/`, `sources/`) |
| FelixKa's work | postmarketOS `pmaports` device package `lenovo-cd-18781y`, and the HA forum thread `community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324` |

## Rules

- **Read only.** Do not write to any eMMC partition, `/dev/block/*`, `/persist`, or `/sys` nodes that change hardware state, unless the brief explicitly allows a specific write. Reading is fine.
- **One user of the device at a time.** The adb link is Wi-Fi only and slow (about 0.6 MB/s). Keep captures small and targeted. Pull large things from the backup images instead of from the device.
- **Do not reboot the device**, change its network settings, or uninstall anything. The device is still the only copy of its runtime state until the stock capture is complete.
- **Never print secrets.** The device has a Wi-Fi PSK and Google account tokens on it.
- **Hazards called out in a brief are binding.** In particular, the VCNL4200 IR LED must not be left on at full power.
- **Do not flash, and do not enter EDL.** Flashing is a separate step with its own checklist.

## Capture the stock runtime first

The stock Android system is the only place some facts can be observed (probe logs, mixer paths, camera tuning, live register state). Once the device is flashed, that is gone. Every brief has a **Stock capture** section listing what to collect from the live device. Do those before anything that depends on the mainline system.

Shared captures go in `../stock/` and are done once, not per device:

- `/proc/device-tree` as a tar, and a decompiled `dtc -I fs` dump.
- full `dmesg` (root), `logcat -d`, `getprop`.
- `/proc/interrupts`, `/proc/iomem`, `/sys/kernel/debug/gpio` and `/sys/kernel/debug/pinctrl/*/pinmux-pins` if debugfs is mounted.
- `/sys/class/regulator/*/{name,microvolts,state}` and `/sys/kernel/debug/clk/clk_summary` if present.
- `lsmod`, `/vendor` and `/system/etc` firmware and config listings, `/vendor/firmware` and `/firmware` file lists with sizes and hashes.

## Fixes

[`fixes/`](fixes/README.md) holds reviewable patches that come out of the analyses (currently one DTS patch for the gaps found so far). Nothing there is built or flashed.

## Devices

| Directory | Hardware |
| --- | --- |
| [`_inventory`](_inventory/BRIEF.md) | Find every device on the board, including any not listed here |
| [`debug-uart`](debug-uart/BRIEF.md) | Serial console (`uart_0`) |
| [`storage-emmc`](storage-emmc/BRIEF.md) | eMMC, partition layout |
| [`firmware-remoteproc`](firmware-remoteproc/BRIEF.md) | ADSP and other remote processors, firmware loading |
| [`usb`](usb/BRIEF.md) | USB-C port, gadget networking, OTG |
| [`wifi`](wifi/BRIEF.md) | QCA9379 SDIO |
| [`bluetooth`](bluetooth/BRIEF.md) | QCA9379 Bluetooth over UART |
| [`display-panel`](display-panel/BRIEF.md) | DSI panel |
| [`backlight`](backlight/BRIEF.md) | PMI8950 WLED |
| [`touch`](touch/BRIEF.md) | FocalTech FT8201 or Himax HX83100A |
| [`gpu`](gpu/BRIEF.md) | Adreno 506 |
| [`video-decode`](video-decode/BRIEF.md) | Venus |
| [`speaker`](speaker/BRIEF.md) | TI TAS5782M |
| [`microphones`](microphones/BRIEF.md) | DMIC array |
| [`echo-cancellation`](echo-cancellation/BRIEF.md) | AEC on the speaker and mic path |
| [`camera`](camera/BRIEF.md) | Camera sensor and CAMSS |
| [`privacy-switches`](privacy-switches/BRIEF.md) | Camera lens cover and mic mute switches |
| [`buttons`](buttons/BRIEF.md) | Power and volume keys |
| [`proximity-light`](proximity-light/BRIEF.md) | Vishay VCNL4200 |
| [`accelerometer`](accelerometer/BRIEF.md) | Bosch BMA253 |
| [`cpufreq-thermal`](cpufreq-thermal/BRIEF.md) | CPU scaling, thermal sensors, throttling |
| [`power-management`](power-management/BRIEF.md) | Screen off and on, suspend, idle |
