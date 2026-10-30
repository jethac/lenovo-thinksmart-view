# Backlight

## What this is

PMI8950 WLED (`&pmi8950_wled`), plus the panel's backlight enable GPIO 95, LAB/IBB supplies for the panel.

## Done when

Brightness is smooth across the full usable range, off is truly off, and it comes back after blank and unblank.

## Known so far

- rickx: range 0 to 4095; values below about 1200 turn the display off. The rickx daemons use brightness 10 as "dark but alive" to avoid DRM off.

## Stock capture

- Stock WLED settings from the device tree (`qcom,leds-wled` or `qcom,qpnp-wled` node: current per string, number of strings, boost frequency, OVP, CABC).
- The stock brightness curve: map of `/sys/class/leds/lcd-backlight/brightness` (or equivalent) to perceived brightness at a few points.

## Questions

- Are the mainline WLED settings (`qcom,num-strings`, current limits, OVP) the same as stock? A mismatch can damage LEDs or cause the low-end cutoff.
- Is the cutoff at about 1200 a real hardware minimum or a mis-set WLED parameter?
- CABC (content adaptive backlight): used on stock, wanted here?

## Hazards

- Do not raise WLED current limits above stock.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
