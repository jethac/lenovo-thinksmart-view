# Speaker amplifier

## What this is

The 10 W full-range speaker through a TI TAS5782M class-D amplifier on `&i2c_1`, fed by quaternary MI2S from the ADSP (`&q6afedai` `dai@22`, `quaternary-mi2s-dai-link` in `&sound_card`).

## Done when

Clean playback at full volume through PipeWire, with no pops at start and stop, no clipping at 100%, and volume control that maps sensibly.

## Known so far

- rickx: works with a custom `tas5782m` driver plus WirePlumber policy forcing S16LE (S24_LE plays near silent; S32 is rejected). Needs `tas5728m_dsp_lenovo_cd-18781y.bin` firmware and the I2C pinctrl fix service. See `../../ubuntu-thinksmart/AUDIO.md` and `sources/driver/`.
- FelixKa extended the upstream TAS5805M driver to cover the TAS5782M (`sources/driver/felixka-reference/`).
- The TAS5782M has its own DSP. Lenovo ships coefficients for it (speaker EQ and protection).

## Stock capture

- `/vendor/etc/mixer_paths*.xml`, `audio_platform_info*.xml`, `audio_policy_configuration.xml`, and ACDB files (`/vendor/etc/acdbdata/`). rickx captured some in `research/audio/inventories`.
- Where the TAS5782M DSP coefficients come from on stock (firmware file, or tables in the kernel driver in Lenovo's GPL source). Hash them.
- The stock I2C address and the init register sequence from the Lenovo GPL driver.

## Questions

- 7.3 has no `ti,tas5782m` driver. Compare the FelixKa (TAS5805M-based) and rickx drivers, pick a base, and work out what upstream review would ask for.
- Root cause of the S24_LE near-silence (data alignment between Q6 AFE and the amp's I2S format).
- Speaker protection: does the stock DSP blob limit excursion? Playing without it at full power could damage the speaker.

## Hazards

- Do not play full-scale test tones without the stock DSP coefficients loaded.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
