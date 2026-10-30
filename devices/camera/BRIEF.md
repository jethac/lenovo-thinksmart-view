# Camera

## What this is

The front camera. On this unit it is a **Samsung S5KC505A**: the stock kernel registered a V4L2 sub-device named `s5kc505a`. Mainline has the SoC side (`camss@1b00020`, `qcom,msm8953-camss`, CSI PHYs, CCI) in `msm8953.dtsi`, but `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` has no board-level camera nodes.

## Done when

Live preview and stills through libcamera at the sensor's native modes, correct orientation, and the lens cover switch respected.

## Known so far

- Stock device tree: three camera slots on CCI master 0. `camera@0` (CSI PHY 0, CSID 0) and `camera@2` (CSI PHY 2, CSID 2) are enabled, `camera@1` is disabled. All have mount angle 270 and sensor position 1 (front). Three EEPROM slots and two actuator slots are also defined.
- Stock vendor partition has tuning (chromatix) libraries for `s5kc505a`, `ov5693`, `s5k4e8` and a test pattern sensor. Lenovo supported several sensors, so units may differ.
- FelixKa had a commented-out placeholder (`mipi-ccs` at `0x2d`, reset GPIO 40, rotation 270). rickx replaced it with an OV5693 at `0x36` on CSI PHY 0, from Lenovo's `apq8053-camera-sensor-dragon.dtsi`. That does not match this unit.
- rickx's reverse-engineering notes: `../../ubuntu-thinksmart/research/camera/analysis/` (S5KC505A notes and driver plan).

## Stock capture

- Which slot the S5KC505A is on, its I2C address on CCI, MCLK frequency, reset and power-down GPIOs, regulators and power-up sequence. Get these from the stock DT slot properties and the sensor library or `msm_sensor` probe log.
- `libmmcamera_s5kc505a.so` and the matching chromatix libraries, hashed and copied (they hold register init tables for each mode, which a mainline driver needs).
- EEPROM / OTP contents if readable (lens shading and colour calibration).
- Stock camera HAL media topology (`media-ctl -p` if present) and supported resolutions.

## Questions

- Is the S5KC505A MIPI CCS compliant? If so, the generic `ccs` driver might work with a DT node only.
- If not, what is the minimum driver: modes, exposure, gain, test pattern, link frequency?
- State of CAMSS for msm8953 in 7.3 (is it in tree, tested on any msm8953 phone?), and libcamera support for CAMSS (simple pipeline handler with software ISP).
- Is there an actuator (autofocus) on this unit, or fixed focus?
- What does the lens cover switch do electrically: report only, or cut sensor power?

## Hazards

- Wrong regulator voltages can damage the sensor. Take voltages from the stock device tree, not from a different board.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
