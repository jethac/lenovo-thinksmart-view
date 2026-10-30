# Touchscreen

## What this is

The touch controller. Mainline has two candidates on `&i2c_3`, both `status = "disabled"` in `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts`: `focaltech,ft8201` at `0x38` and `himax,hx83100a` at `0x48`, sharing IRQ GPIO 65 and reset GPIO 64.

## Done when

All touch points work at the right coordinates in every rotation, and a touch can wake the screen (or the reason it cannot is documented with a workaround).

## Known so far

- **This unit is the FocalTech variant.** Stock loaded `fts_ts` as an input device, and the panel is `boyift8201`. rickx documented an HX83100A, so rickx's unit is the other variant.
- Both nodes are disabled in the DTS, so something (probably lk2nd, or a DT overlay selected by panel) must enable the right one.
- On a TDDI part, touch shares the panel controller. Turning the panel off can kill touch, which explains "touch cannot wake the screen" reports.

## Stock capture

- Stock driver name, I2C address and probe log (`dmesg | grep -i fts`), firmware version, `/proc/device-tree` touch node with all properties.
- Touch firmware file on stock (`/vendor/firmware/*ft8201*` or built into the driver), and whether the driver flashes it at boot.
- Gesture or wake features in the stock driver (`fts_gesture`, `wakeup` sysfs).

## Questions

- In 7.3 (and 7.1.3), `focaltech,ft8201` is handled by `drivers/input/touchscreen/edt-ft5x06.c` and `himax,hx83100a` by `himax_hx83112b.c`. Check that the FT8201 support there covers this unit's firmware (multi-touch count, coordinate range, report format).
- How does the kernel decide which touch node to enable on this unit?
- Can touch stay powered while the panel is in sleep (for wake on touch)?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
