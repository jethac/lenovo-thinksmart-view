# Proximity and ambient light

## What this is

Vishay VCNL4200 proximity and ambient light sensor at `0x51` on the bit-banged `i2c-gpio` bus (`i2c-sensors` in `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts`). The node is disabled with a warning that it can burn out the sensor's IR LED.

## Done when

Approaching the screen wakes it, ambient light drives backlight brightness, and the IR LED is only on when proximity is actually being sampled.

## Known so far

- The upstream `vcnl4000` driver enables the IR LED at high current continuously, so the sensor gets warm. rickx avoided it with a userspace daemon that drives the registers over `/dev/i2c-0` and only enables the LED while the screen is off. See `../../ubuntu-thinksmart/README.md` (VCNL4200 section) and `sources/vcnl4200-proximity-daemon.py`.

## Stock capture

- Stock driver for the sensor (Android sensors HAL or a kernel driver), its register settings (LED current, duty cycle, integration time), and the proximity threshold.
- Is the sensor read through the ADSP on stock (sensors are normally proxied there)?

## Questions

- Current state of `drivers/iio/light/vcnl4000.c` in 7.3: does it have runtime PM that turns the LED off, and can LED current and duty be set from DT?
- Would a small driver change (LED off unless the proximity channel is enabled, conservative current) be accepted upstream?

## Hazards

- **Binding:** do not enable the DT node with the current upstream driver, and do not set LED current above the stock value or leave the LED on continuously.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
