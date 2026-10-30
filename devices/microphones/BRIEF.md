# Microphones

## What this is

The dual microphone array. The mainline DTS enables `&wcd_codec` and `&lpass`. The DMICs are probably on the MSM8953 internal digital codec.

## Done when

Both microphones capture as separate channels at a usable level and noise floor, and the hardware mute switch is reflected correctly.

## Known so far

- rickx: DMIC works with a UCM2 HiFi profile.
- The mic mute switch (GPIO 86) is a hardware mute; see `../privacy-switches`.

## Stock capture

- Stock mixer paths for DMIC capture, the ACDB tuning for the mic path, and which DMIC lines are used.
- Physical mic positions and spacing (teardown photos or measurement), needed for beamforming and echo cancellation.
- A short stereo test capture on stock (`tinycap` if present) to compare levels with mainline. Do not record speech in the room without the user's agreement.

## Questions

- How many DMIC data lines and which clock rate? Both mics on one line (stereo DMIC) or two?
- Gain staging: digital gain in the codec versus software.
- Does Lenovo's stock audio path do beamforming or noise suppression in the ADSP (Fluence)? Can mainline use the ADSP for that, or is it software only?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
