# Speaker amplifier — ThinkSmart View CD-18781Y

## 1. Summary

TI TAS5782M at I2C `0x49`, fed by quaternary MI2S from the ADSP, driving a 10 W full-range speaker from a 20 V rail switched by GPIO 68. The amplifier has its own DSP, and Lenovo's tuning for it is **not a firmware file on the device** — it is a 1535-entry register patch embedded in Lenovo's GPL `tas5782m.h`. That patch is the speaker EQ and excursion protection, so it is not optional. Mainline has a complete and plausible node but no driver, and two of its GPIO properties do not match what the stock driver and live pads show.

## 2. Identity

- `tas5782m@49`, `compatible = "ti,tas5782m"`, `reg = <0x49>` on `&i2c_1`; live device `1-0049`, driver name `tas5782m`.
- Stock GPL driver: `sound/soc/codecs/tas5782m.c` (643 lines) + `tas5782m.h` (1559 lines). The header begins `static struct reg_default tas5782m_init_sequence[]` with 1535 `{reg, val}` pairs — the whole DSP program.
- Enable: `qcom,audio_enable_gpio68 = <&tlmm 68 0>`, driven high at probe, with pinctrl state `audio_enable_default_gpio`.
- Amplifier supply: `speaker_amp_pvdd`, fixed 20 V regulator on GPIO 68 (mainline DTS), `vin-supply = <&vph_pwr>`.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Bus / address | `i2c_1` @ `0x49` | same | yes |
| Rail enable | GPIO 68, output high in probe, `audio_enable_default_gpio` | `speaker_amp_pvdd` fixed 20 V regulator on GPIO 68 | same pin, different model |
| PDN | **not modelled**; live pad is `in 0 2mA pull down` | `pdn-gpios = <&tlmm 44 GPIO_ACTIVE_LOW>`, live pad also `in` with pull-down | **contradiction** |
| Mute | not modelled | `mute-gpio = <&tlmm 0 GPIO_ACTIVE_HIGH>` | suspect (pin 0) |
| Fault | not modelled | `fault-gpio = <&tlmm 45 GPIO_ACTIVE_HIGH>`, live pad `in` with pull-down | plausible |
| I2S | `pri_mi2s`, GPIO 88-93 (live owner `c051000.sound`) | inherited | yes |
| DSP tuning | 1535-entry kernel patch | `ti,dsp-config-name = "lenovo_cd-18781y"` + firmware file via the port's driver | **different mechanism** |

## 4. Stock behaviour

- Vendor driver: probe looks up the pinctrl state, gets GPIO 68, sets it **output high**, then registers the 1535-entry `reg_default` patch through `regmap_register_patch`, then programs sample rate and DAPM routes. No `request_firmware` anywhere in the stock driver, and no `tas57*` file exists in `/vendor/firmware`, `/vendor/etc` or `/system` — confirmed by search.
- Mute is done through register `TAS5782M_CTRL3` (soft mute), not a GPIO.
- Volume is a register write; there is no hardware volume pin.
- `audio_tuning_mixer.txt` and `mixer_paths_mtp.xml` exist in `/vendor/etc`, but they configure the ADSP routes, not the amplifier DSP — the amplifier coefficients are entirely the kernel patch.

## 5. Mainline state

- Node present, enabled, with `sound-name-prefix`, `ti,dsp-config-name`, PVDD regulator and PDN GPIO.
- **No `ti,tas5782m` driver in 7.1.3 or 7.3.**
- The prior port has a working driver (`sources/driver/tas5782m.c` + `_dbg`/`_tables`) which loads `tas5728m_dsp_<config>.bin` — the same coefficients, converted to a firmware blob — and runs S16LE only because S24_LE plays near-silent and S32 is rejected.
- FelixKa's reference is an extension of the upstream `tas5805m` driver, i.e. a more upstream-shaped base but for a sibling part.
- Two node properties are unverified: `pdn-gpios` on 44 while stock never drives 44, and `mute-gpio` on pin **0**, which is an otherwise unused TLMM pin.

## 6. Gap and plan

1. Decide the polarity question first, because it gates everything: on a TAS5782M, PDN low puts the amp in shutdown. Stock leaves 44 pulled low and never drives it, yet audio works, so either the board pulls 44 up externally or 44 is not PDN. Probe the pad with a meter while the amp is playing on stock, then model it correctly.
2. Pick a base driver: FelixKa's TAS5805M-derived one (upstream shape, reviewable) and add the TAS5782M specifics, or rickx's 5782 driver as the fast path. Port the 1535-entry patch as the firmware blob (`tas5728m_dsp_lenovo_cd-18781y.bin`) because a 1535-line header will not be accepted upstream.
3. Fix the sample-format problem properly: find where Q6 AFE and the amp's I2S word length disagree, rather than pinning S16LE in WirePlumber.
4. WirePlumber policy + UCM2 profile from `../../ubuntu-thinksmart/`, then test: silence at start/stop (no pops), sweep volume 0-100 %, and a 1 kHz tone at full scale **with** coefficients loaded.
5. Verify GPIO 68 sequencing: rail up, 10+ ms settle, then register programming — the reverse on shutdown, with mute first.

## 7. Risks (binding)

- **Full-scale without the DSP coefficients risks the speaker**: the patch contains the excursion/thermal protection. Play nothing loud before it is loaded.
- Wrong PDN polarity means the amp is either always in reset or never powered down, both silent failures.
- 20 V PVDD into a 10 W driver can cook the voice coil quickly if a test tone is left running.
- GPIO 68 also sequences the rail; programming registers before the rail is stable can latch the amp into an undefined state.

- **Playback cannot be tested on stock with what is installed**: there is no `tinyplay`/`tinycap`/FTM tool, Termux `am`/`termux-media-player` crash on this ROM, no music player app, and a raw write to `/dev/snd/pcmC0D0p` produces no sound because the AFE route is never set. Speaker verification therefore starts on mainline.

**Playback cannot be tested on stock with what is installed**: no `tinyplay`/`tinycap`/FTM tool, Termux `am` and `termux-media-player` crash on this ROM, no music player app, and a raw write to `/dev/snd/pcmC0D0p` produces no sound because the AFE route is never set. A raw PCM write did wedge the USB link once; see `../../stock/README-boot-capture-20261030.md`. Speaker verification therefore starts on mainline.

## 8. Open questions

- Is GPIO 44 PDN at all, and is it externally pulled up? Same question for the pin-0 "mute" placeholder.
- Do the stock coefficients correspond byte-for-byte to what rickx ships as `.bin`? A diff would confirm the port kept the real tuning.
- Why is S24_LE near-silent — word length, slot width, or clock-phase on the Q6 side?
- Would upstream accept a firmware-based coefficient load for a codec that ships its tuning as a downstream header?

## 9. Sources

- Live 2026-10-30: `/sys/bus/i2c/devices/1-0049`, `debugfs/gpio` (pins 44, 45, 68); `evidence/stock-audio-files-20261030.txt`.
- GPL `sound/soc/codecs/tas5782m.c:243-250,382-440,525-561`, `tas5782m.h:3-1559`; `apq8053-lite-dragon-v2.0.dtsi:60-67`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:145-160,248-264`.
- `../../ubuntu-thinksmart/AUDIO.md`, `sources/driver/tas5782m.c`, `sources/driver/felixka-reference/tas5805m-felixka.c`; `speaker/BRIEF.md`.
