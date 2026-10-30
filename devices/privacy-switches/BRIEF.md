# Privacy switches

## What this is

The camera lens cover switch (GPIO 87, `SW_CAMERA_LENS_COVER`) and the microphone mute switch (GPIO 86, mapped to `SW_MICROPHONE_INSERT` because there is no better input code) in the mainline `gpio-keys` node.

## Done when

Both switch states are readable from userspace, the full-screen app shows them, the camera stack refuses to stream with the cover closed (or the hardware makes that moot), and capture is muted when the mic switch is on.

## Known so far

- The mainline DTS comment says the mic switch is a hardware mute: the mics are muted whatever software does.

## Stock capture

- How stock reports these: input events (`getevent -lp` to list devices and codes), and any Lenovo service or system property that reacts.
- Any LED tied to either switch.

## Questions

- What exactly does each switch cut? Mic data line, mic power, or only a GPIO? Same for the camera: shutter only, sensor power, or GPIO only? Check with the switch toggled and the stock `dmesg`/regulator state.
- Is `SW_MICROPHONE_INSERT` the best available mapping today, or has a mute switch code been added upstream since?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
