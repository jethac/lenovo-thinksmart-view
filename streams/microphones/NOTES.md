# Microphones

Status 2026-11-03: the DMIC clock series builds clean on top of `kernel/patches/` and was tested on the device. Both microphones capture the same at 2.4 MHz as at 3.2 MHz on this unit. The device is back on the baseline kernel.

## What was done

The internal digital codec's DMIC clock change from justhalfbit's Ubuntu image for the ThinkSmart View (`codec-dmic/msm8916-wcd-digital-dmic-clock.patch`, MIT, written against pmOS 6.19) was ported to 7.3 and split into upstream-style patches.

| Patch | What it does |
| --- | --- |
| `kernel/patches-wip/microphones/0501-ASoC-dt-bindings-qcom-msm8916-wcd-digital-codec-add-.patch` | Binding: optional `qcom,dmic-sample-rate` (Hz, 600000-6144000), the highest DMIC clock the board can take. Same name and meaning as in the LPASS VA/WSA macro bindings. |
| `kernel/patches-wip/microphones/0502-ASoC-codecs-msm8916-wcd-digital-set-the-DMIC-clock-p.patch` | Fix: the decimator's DMIC clock select (`TXn_DMIC_CTL`) is written from the decimator's DAPM event instead of from the DMIC line's event, keyed by DMIC number. Still MCLK/3. Removes the parsing of the DMIC number from the widget name. |
| `kernel/patches-wip/microphones/0503-ASoC-codecs-msm8916-wcd-digital-make-the-DMIC-clock-.patch` | Feature: with the property, the fastest divider from 2, 3, 4, 6 and 16 whose output does not exceed it, used for the clock generator (`CLK_DMIC_B1_CTL`) and every decimator. Without the property, or with MCLK rate 0, the divider stays at 3. |
| `kernel/patches-wip/microphones/0504-arm64-dts-qcom-apq8053-lenovo-cd-18781y-run-the-DMIC.patch` | Board: `&lpass_codec { qcom,dmic-sample-rate = <2400000>; }`, the vendor rate (stock `qcom,cdc-dmic-sample-rate = <0x249f00>`). |

How this differs from the reference patch:

- The fix and the configurable rate are separate patches, so the fix can go to stable on its own.
- With no property the divider is a fixed 3, not "the fastest not above 3.2 MHz". That is the same at the 9.6 MHz MCLK every in-tree board uses, but at 12.288 MHz MCLK the reference patch would quietly move existing boards from 4.096 to 3.072 MHz.
- `FIELD_PREP()` for the generator field instead of `<< 1`.

checkpatch: clean on all four. `dt_binding_check` on the binding: clean (dtschema in a venv on the Shared partition). `CHECK_DTBS` on the board DTB: no complaint about the new property; the one warning is the existing `clock-names` order in `msm8953.dtsi` (`"mclk", "ahbix-clk"` against the binding's `ahbix-clk, mclk`), not touched here.

### About the bug

`TXn_DMIC_CTL` must match the clock generator's divider, or the decimator reads the data line at the wrong rate and gives full-scale noise. The old code wrote TX1 when DMIC1 powered up and TX2 when DMIC2 did. On this board that does not bite in practice: the listener routes `DEC1 = DMIC1`, `DEC2 = DMIC2`, and stock's crossed routing (`DEC1 = DMIC2`, `DEC2 = DMIC1`) also powers both DMICs, so both registers get written. It does bite when one decimator uses the other DMIC number while that DMIC is not powered (for example `DEC1 = DMIC2` alone, or both decimators on one DMIC), when nothing has written the register since boot, and with any rate other than MCLK/3 combined with crossed routing. That last case is how it showed up in the reference work. I did not reproduce the failure: on a running baseline the listener has already written both registers with the right value at boot.

## Measurements

Method: under the device lock, stop `straylight-listen`, run one `arecord -D hw:0,1 -f S16_LE -c2 -r48000 -d 22` (one open, one prepare). During it: 10 s of room tone, then a 10 s LibriVox clip (loudness normalised to -20 LUFS) played through `aplay -D hw:0,0` with the amp at 187 (-10 dB). Then a 6 s room-tone capture with stock's crossed routing (`DEC1 MUX = DMIC2`, `DEC2 MUX = DMIC1`). Then the straight routing is put back, the amp goes back to 207, and the listener restarts. The listener was down about 30 s each time. Mixer: CIC = DMIC, `TX1/TX2 Digital Volume` 108 (+24 dB, the listener's setting). Analysis on the host skips the first 0.5 s (start-up transient at full scale, the same on every run and both kernels). The codec registers were read from regmap debugfs after each capture.

Registers: baseline `CLK_DMIC_B1_CTL` sel 1, `TX1/TX2_DMIC_CTL` 1 (MCLK/3 = 3.2 MHz). Patched: `CLK_DMIC_B1_CTL` sel 2, `TX1/TX2_DMIC_CTL` 2 (MCLK/4 = 2.4 MHz), the same with the crossed routing.

Speech window (11.5-21 s) and room window (1-10 s). dBFS at +24 dB digital gain. p10 is the 10th percentile of 50 ms frame RMS.

| Run | Ch | Room RMS | Room p10 | Room peak | Speech RMS | Speech peak | Speech − room | 16-24 kHz room |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline 3.2 MHz | DMIC1 (ch0) | -54.8 | -55.9 | -39.6 | -47.8 | -27.9 | 7.0 dB | -62.4 |
| | DMIC2 (ch1) | -55.1 | -56.0 | -41.3 | -50.0 | -31.1 | 5.1 dB | -61.0 |
| patched 2.4 MHz | DMIC1 (ch0) | -55.5 | -56.5 | -41.7 | -48.5 | -28.8 | 7.0 dB | -63.3 |
| | DMIC2 (ch1) | -55.7 | -56.4 | -41.8 | -50.6 | -30.9 | 5.1 dB | -61.8 |
| baseline again 3.2 MHz | DMIC1 (ch0) | -55.6 | -56.5 | -42.0 | -48.2 | -27.8 | 7.4 dB | -63.5 |
| | DMIC2 (ch1) | -55.9 | -56.7 | -42.2 | -50.2 | -30.7 | 5.7 dB | -62.6 |

Inter-channel correlation (200-4000 Hz band): room 0.78 / 0.76 / 0.74, speech 0.65 / 0.64 / 0.63 (baseline / patched / baseline again). Channel offset in speech: DMIC1 is 2.0-2.2 dB louder on every run. Crossed routing: both channels -55 to -56 dBFS on both kernels, no full-scale noise. No sample above -1 dBFS outside the start-up transient on any run. DC offset is about zero everywhere.

Reading: the differences between the kernels (at most 0.7 dB) are no bigger than the differences between the two baseline runs, so the room's ambient noise varies between sessions. The room noise is mostly ambient, not mic self-noise: it is well correlated between the mics and about -79 dBFS at 0 dB gain, against the -81.5 dBFS the wakeword stream measured in a quieter room. On this unit DMIC1 is clean at 3.2 MHz too. The reference patch says DMIC1 is only clean at 2.4 MHz. Either that varies from unit to unit, or what was seen there was the decimator mismatch.

Capture files (host only, not in the repo): `streams/microphones/work/cap/mic-{base,fix,base2}-{main,crossed}.wav`.

The QDSP6 did not wedge: each PCM was opened once per capture, PipeWire was never involved, and the listener came back every time.

## Recommendation

Accept all four into the baseline.

- 0502 fixes a real bug in the driver and changes nothing for the default rate or for this board's current routing.
- 0501 and 0503 change nothing without the property.
- 0504 matches the vendor rate and measured the same as 3.2 MHz here. It is the safe choice for units where DMIC1 is marginal at 3.2 MHz, and it makes a stock-style crossed routing safe as well.

Upstreamability: good. The touched file `sound/soc/codecs/msm8916-wcd-digital.c` is maintained under Qualcomm ASoC (Srinivas Kandagatla); the property name already exists in `qcom,lpass-va-macro.yaml` and `qcom,lpass-wsa-macro.yaml`. To do before sending:
- Add a `Fixes:` tag to 0502 for the commit that added DMIC support to this driver. The local tree is shallow, so I could not look up the hash.
- Agree with justhalfbit on how to credit them. Their real name or address is needed for a `Reported-by:`/`Co-developed-by:` tag; until then 0502 credits them in prose only.
- 0504 depends on the board DTS, which is still in msm8953-mainline and not upstream.
- `CHECK_DTBS` on msm8953 boards shows the existing `clock-names` order mismatch in `msm8953.dtsi`; that is a separate fix.

## Left on the device

Nothing. The baseline kernel (`build-7.3`) is installed and running. `kernel/deploy-to-device.sh` kept the test kernel as `*.prev`, as usual. Mixer state is as before: `DEC1 = DMIC1`, `DEC2 = DMIC2`, TX 108, amp 207. `straylight-listen` is active. The temporary files in the device's `/tmp` have been removed.

## Laptop side

- `/home` was full (about 800 MB free), and the first build died linking `vmlinux.o` (SIGBUS). `kernel/build-microphones` is now a symlink to `/run/media/jethac/Shared/lenovo-8-kbuild/build-microphones`. The `.gitignore` pattern `kernel/build-*/` does not match a symlink, so it shows as untracked; do not commit it. The dtschema venv is at `/run/media/jethac/Shared/lenovo-8-kbuild/dtvenv`.
- Worktree `kernel/wt-microphones` (branch `ws/microphones`, at the base commit), plus `ws/microphones-work`, which holds the four commits as authored. The patch files' commit messages were edited afterwards (0503 and 0504 wording, 0504 DTS comment). The patch files are the reference.
- The deployed test kernel had the older DTS comment; the property value was identical.
