# Accelerometer

## What this is

Bosch BMA253 at `0x18` on the bit-banged `i2c-sensors` bus (`compatible = "bosch,bma253"`, `bmc150-accel` driver).

## Done when

Screen rotation follows the device orientation in all four directions under Hyprland, with the right mount matrix.

## Known so far

- rickx: works with `iio-sensor-proxy`, plus a rotation daemon calling `kscreen-doctor` (Plasma only; Hyprland needs its own).

## Stock capture

- Stock sensor orientation settings (sensor HAL config, or DT `mount-matrix` equivalent).
- Readings with the device in each of its four orientations (from a sensor dump tool on stock, if available), for checking the mount matrix.

## Questions

- Is `mount-matrix` in `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` correct for this unit?
- Interrupt line wired? Polling versus interrupt mode.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
