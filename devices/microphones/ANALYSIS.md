# Microphones — ThinkSmart View CD-18781Y

## 1. Summary

The array is a **single-line stereo DMIC**: DMIC clock on GPIO 89 (`dmic0_clk`), data on GPIO 90 (`dmic0_data`), feeding codec digital inputs DMIC1/DMIC2, captured through DEC1/DEC2. On stock the path is ADSP-mediated, with `DEC1 MUX = DMIC2` and `DEC2 MUX = DMIC1` and the Fluence noise suppression/beamforming module (`fluence_voiceplus_module.so.1`) loaded on the DSP. Mainline's DTS models the same routing, but the pin states are typed as plain GPIO at runtime and the whole capture chain needs exercising from zero. Mic positions/spacing are not yet measured, which matters for beamforming and AEC.

## 2. Identity

- Pins: `cdc_dmic0_clk_act` = `gpio89` `function = "dmic0_clk"`, `cdc_dmic0_data_act` = `gpio90` `function = "dmic0_data"`, with matching `_sus` sleep states (7.3 DTS, `dmic0-clk-on-pins` / `dmic0-data-on-pins`).
- Codec inputs: `Digital Mic1`, `Digital Mic2`, both on `MIC BIAS Internal1`; routing "DMIC1"→"Digital Mic1" and "DMIC2"→"Digital Mic2" under `&sound_card` (`:370-380`).
- Stock equivalent: identical routing names in `qcom,audio-routing`, plus `qcom,cdc-dmic-sample-rate = <0x249f00>` (2.4 MHz) in the codec node.
- Stock mixer path (from `/vendor/etc/mixer_paths_mtp.xml`): `DEC1 MUX = DMIC2`, `DEC2 MUX = DMIC1`, `DEC1/DEC2 Volume = 115`, `ADC1-3 Volume = 4-6` (`evidence/stock-mic-mixer-paths-20261030.txt`).

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| DMIC clock | GPIO 89, `dmic0_clk` | same (`cdc_dmic0_clk_act`) | yes |
| DMIC data | GPIO 90, `dmic0_data` | same | yes |
| Channel count | 2 (stereo on one data line) | 2 via DMIC1/DMIC2 | yes |
| Sample rate (codec) | 2.4 MHz DMIC clock | inherited from `wcd_codec` | to verify |
| Gain staging | DEC 115, ADC 4-6 | not set anywhere on mainline | gap |
| Live mux | `c051000.sound`, pins 89/90 currently `function gpio` | pinctrl states defined | see §5 |
| Bias | `MIC BIAS Internal1` | same | yes |

## 4. Stock behaviour

- Capture is an ADSP use case (`MultiMedia1` capture device exists on card 0), with ACDB calibration in `/vendor/etc/acdbdata/MTP/` and mixer paths applied by the Android audio HAL.
- DEC volume 115 is close to the top of the codec's range: stock runs the digital gain hot and relies on ACDB/Fluence to keep levels sane.
- Fluence voice-plus is present in `/dsp` (`fluence_voiceplus_module.so.1`), which is the ADSP noise-suppression/beamforming module. Stock therefore gets its array processing on the DSP, not in userspace.
- No `tinycap` binary on stock, so a reference capture needs another recorder.

## 5. Mainline state

- DTS routing, pinctrl states and both channels are in place; `&wcd_codec` and `&lpass` are enabled.
- The live pads are owned by `c051000.sound` but muxed as plain `gpio`, not `dmic0_clk`/`dmic0_data` — that is the state left by the card's current (speaker) pinctrl selection, and must switch on first capture.
- No gains set anywhere: mainline defaults are whatever the codec resets to, not stock's DEC 115.
- Fluence is not usable without the ADSP; AEC/NS has to come from PipeWire/WebRTC (see `../echo-cancellation/`).
- **There is no hardware mute provider.** Measured 2026-10-30: the only switch on the unit is the camera shutter and it does not affect capture (`../privacy-switches/`), so muting is purely a software policy here.

## 6. Gap and plan

1. Accept that muting is software-only (measured — see `../privacy-switches/` §4) and make the policy explicit rather than assuming a hardware cut.
2. Capture stereo with `arecord -D hw:0,0 -f S16_LE -c 2 -r 48000` and confirm both channels carry different signal — one data line with two slots means a broken L/R assignment shows up as identical channels.
3. Set gain to a known point (DEC 115, ADC 6) from UCM2, capture a known source, and record the noise floor with the mics open and with the mute on.
4. Measure mic positions (a ruler on the front bezel is enough) so a beamforming/AEC geometry exists; note it in this file rather than in a daemon.
5. Fit the sample rate: confirm the DMIC clock divider actually yields 2.4 MHz at 48 kHz, and test 16 kHz too (wake-word rate).
6. Test with the speaker at full volume underneath the capture, which is the real AEC condition.

## 7. Risks

- Leaving DEC at max gain with no ACDB produces clipping on loud speech; clipping cannot be undone downstream.
- A wrong DMIC clock rate gives either silence or aliased noise, not an obvious error.
- The single data line carries both channels; a mis-set slot map silently duplicates one mic.
- `MIC BIAS Internal1` is shared with the amp enable path — sequencing errors pop in the speaker.

## 8. Open questions

- Are both mics really on one data line, or is the second one on another `dmic*_data` pin not modelled?
- What is Lenovo's ACDB calibration for this array, and is any of it usable without the ADSP?
- How far apart are the mics, and is the array end-fire (top edge) or broadside?
- With no hardware mute, should the desktop expose a mic-mute toggle that is enforced in PipeWire?

## 9. Sources

- `evidence/stock-mic-mixer-paths-20261030.txt`; live `debugfs/pinctrl` (pins 89/90), `/proc/asound/card0`.
- `../stock/stock-device-tree.dts:11831` (DMIC sample rate).
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:355-380,642-664`.
- `../../ubuntu-thinksmart/README.md` (UCM2 HiFi profile); `microphones/BRIEF.md`.
