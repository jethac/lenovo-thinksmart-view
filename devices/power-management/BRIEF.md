# Screen off and power management

## What this is

Turning the screen off and on, idle behaviour, and system suspend. Covers the panel, backlight and touch interplay, and what wakes the device.

## Done when

The screen can turn off and back on repeatedly (from idle, from a key, from proximity) without restarting the compositor. Idle power is measured. Whether system suspend works is known.

## Known so far

- rickx: on Plasma 6, DRM connector off could not be recovered without restarting KWin. They worked around it by never turning the panel off and dimming the backlight instead.
- The device has no battery. Suspend matters for heat and power use, not runtime.

## Stock capture

- How stock turns the screen off and on (does it power down the panel or only blank?), from logcat and `dmesg` across a screen off and on.
- Wake sources configured on stock.

## Questions

- Root cause of the unrecoverable DPMS off: panel driver prepare and unprepare sequence, TDDI reset, LAB/IBB regulators, or MDSS.
- Does s2idle or deep suspend work on msm8953 mainline, and what can wake it?
- Power draw at idle with the screen on, screen dim, screen off (needs a USB or barrel power meter).

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
