# Hardware inventory

## What this is

Not one device. Find every piece of hardware on the board, so no device is missed, and check the list in `../README.md` against reality.

## Done when

`ANALYSIS.md` has a table of every enabled node in the stock device tree, every I2C, SPI, UART, SDIO and USB peripheral that probed on stock, and every GPIO in use, each mapped to a directory under `devices/` or flagged as new.

## Known so far

- Stock exposes an FM radio V4L device (`radio-iris`). That is normally part of WCNSS, which this board does not use for Wi-Fi. Find out whether FM hardware actually exists.
- Mainline deletes `mpss`, `wcnss` and related memory regions (no modem, Wi-Fi is QCA9379).
- Sensors sit on a GPIO bit-banged I2C bus because BLSP `i2c_2` is protected by TrustZone (sensors are normally proxied through the ADSP).

## Stock capture

- Enabled nodes: walk `/proc/device-tree`, list every node whose `status` is absent, `ok` or `okay`, with `compatible`.
- `/sys/bus/i2c/devices/*/name` and `/sys/bus/i2c/devices/*/modalias`, `/sys/bus/platform/devices`, `/sys/bus/spi/devices`, `/sys/bus/sdio/devices`.
- `/sys/kernel/debug/gpio` (claimed GPIOs and their labels).
- Lenovo board files in the GPL source: `arch/arm/boot/dts/qcom/*8953*lenovo*`, `*dragon*`, `*cd-18781*`, and the board `Kconfig` / defconfig.

## Questions

- Is there anything not in `../README.md`: LEDs (mic mute, camera, status), vibrator, hall sensor, NFC, second microphone path, FM, an extra USB hub or Type-C controller, a fan?
- Are there two hardware revisions (the two touch controllers in the mainline DTS suggest so)? What tells them apart (board ID, panel ID, `qcom,board-id`)?
- What is on each BLSP bus that TrustZone protects, and does that block anything we need?

## Pointers

- Mainline DTS: `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` in `../../kernel/linux-7.3`.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
