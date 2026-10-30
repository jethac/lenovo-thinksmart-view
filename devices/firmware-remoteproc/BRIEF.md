# Remote processors and firmware

## What this is

Every firmware blob the mainline system needs, and the remote processors that run them: ADSP (audio, possibly sensors), Venus (video), the GPU zap shader, QCA9379 Wi-Fi and Bluetooth firmware. Qualcomm signs most of these per OEM, so they must come from this device, not from linux-firmware.

## Done when

A table lists each firmware file mainline requests (from driver source and from `firmware-name` properties), where it comes from on the stock device, its hash, and where it goes on the new root filesystem. A script extracts them from the backup images.

## Known so far

- The rickx image starts ADSP from a systemd service after firmware is available (`adsp-start.service`).
- `/firmware` (`modem` partition, p1) and `/dsp` (p12) hold the signed `.mdt` and `.bNN` files. Partition images are in the backup.
- Mainline DTS has `&gpu_zap_shader` with a `firmware-name`, and `&mpss` / `wcnss` handling for a board without a modem.

## Stock capture

- `ls -la` with sizes and SHA-256 of `/firmware/image`, `/dsp`, `/vendor/firmware`, `/vendor/firmware_mnt` if present, and `/system/etc/firmware`.
- `/sys/kernel/debug/remoteproc` or `/sys/class/subsys` / PIL logs in stock `dmesg` (which images load at boot).

## Questions

- Exact `firmware-name` for ADSP, Venus and the zap shader in `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts`, and the paths postmarketOS uses (`/lib/firmware/qcom/msm8953/lenovo/cd-18781y/...`).
- Which QCA9379 files are needed: `firmware-*.bin`, `board-2.bin` or `bdwlan*.bin`, and where the stock board data lives.
- Does anything need `rmtfs` (modem storage service) even without a modem?
- Firmware licensing: these blobs are Lenovo/Qualcomm property. Keep them out of public git repos.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
