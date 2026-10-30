# Buttons

## What this is

Physical buttons. Mainline: volume up on GPIO 85 (`gpio-keys`, wakeup source), volume down on `&pm8953_resin`, and `&pm8953_pon` `pwrkey` set to **disabled**.

## Done when

Every physical button produces the right input event, and the volume keys (and the power key if it exists) wake the screen.

## Known so far

- justhalfbit lists the controls as power, USB-C, volume +/-, camera shutter, mic mute. FelixKa's DTS says "The device only has a Volume Up and a Volume Down key".
- FelixKa submitted a wake-on-volume fix to pmaports (MR 6832).

## Stock capture

- `getevent -lp`: every input device and its key codes. Press each button with `getevent -l` running and record what fires.

## Questions

- Is there a physical power button? If so, why is `pwrkey` disabled in mainline (stuck line, unwanted reboot, or because it is really the barrel jack)?
- Long-press behaviour on stock (reset, shutdown).

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
