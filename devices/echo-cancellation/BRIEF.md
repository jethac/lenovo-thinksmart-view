# Echo cancellation

## What this is

Acoustic echo cancellation so the microphones stay usable while the speaker plays. On mainline this will most likely be software (PipeWire `module-echo-cancel` with WebRTC AEC), unless the ADSP can do it.

## Done when

With music playing at 65% volume, a speech recognizer on the mic stream still picks up a wake word from across the room at a rate the user accepts. Measured, not just configured.

## Known so far

- justhalfbit (see `../../JHB_REPORT.md`) uses sherpa-onnx for the wake word and has AEC in his design, but had not shown it working as of 29 Oct.
- Speaker output and microphone input are on different hardware paths (MI2S to the amp, DMIC into the internal codec). They may run on different clocks, so drift between them matters to AEC.

## Stock capture

- Whether stock used DSP echo cancellation (ACDB topology IDs for voice or VoIP with EC, Fluence settings in `/vendor/etc` and build props such as `persist.audio.fluence.*`).

## Questions

- Clock relationship between the MI2S playback and DMIC capture paths on mainline. Same master clock or not?
- Round-trip latency from playback to capture, and its stability, which AEC needs.
- CPU cost of WebRTC AEC (and of the speech recognizer) on 8 Cortex-A53 cores.
- Is there a reference loopback path in hardware, or does AEC use the software playback stream?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
