# Backlight — ThinkSmart View CD-18781Y

## 1. Summary

PMI8950 WLED, four strings (0-3), 20 mA per string, 980 mA boost limit, 29.5 V OVP, 800 kHz switching, hybrid dimming with a linear method, external PFET with short-circuit protection. Mainline sets only the per-string current and the PFET flag; every other parameter falls back to driver defaults — and two of those defaults are **above** stock (OVP 32.5 V vs 29.5 V, boost limit 1260 mA vs 980 mA), which is exactly what the brief warns about. Measured today, the low-end cliff is much lower than the prior port reported: the panel stays readable across the whole range and only goes dark at about 1 of 255, so the earlier "below ~1200/4095" figure was not a hardware minimum. Full range needs the stock parameters restored plus an honest look at the hybrid threshold.

## 2. Identity

- `qcom,leds@d800`, `compatible = "qcom,qpnp-wled"`, `linux,name = "wled"`, `linux,default-trigger = "bkl-trigger"`, SPMI base `0xd800` with sink/IBB/LAB bases, `sc-irq` (`../stock/stock-device-tree.dts:11201-11222`).
- Stock LED class: `/sys/class/leds/lcd-backlight`, `max_brightness 255`, current value 10 (panel idle-dim).
- Panel side: `qcom,mdss-dsi-bl-pmic-control-type = "bl_ctrl_wled"`, `bl-max-level 0xfff`, `bl-min-level 1`; the panel's on-command writes `35 00` (backlight control on).

## 3. Wiring and settings

| Parameter | Stock value | Mainline | Verdict |
| --- | --- | --- | --- |
| Strings | `led-strings-list = <0x10203>` → 0,1,2,3 (4) | driver default `num_strings 4`, `enabled_strings {0,1,2,3}` | matches |
| Per-string current | `fs-curr-ua = 0x4e20` = 20000 µA | `qcom,current-limit-microamp = <20000>` | matches, explicit |
| Boost/input limit | `ilim-ma = 0x3d4` = 980 mA | default index 5 = **1260 mA** | **above stock** |
| OVP | `ovp-mv = 0x733c` = 29500 mV | default index 4 = **32500 mV** | **above stock** |
| Switch frequency | `switch-freq-khz = 0x320` = 800 kHz | default index 11 (wled3 formula ⇒ 800 kHz at idx 11) | matches by luck |
| Modulator frequency | `mod-freq-khz = 0x2580` = 9600 kHz | `qcom,modulator-sel`, default 0 | to check |
| Dimming | `dim-mode = "hybrid"`, `dim-method = "linear"` | driver picks dimming mode itself | to check |
| Hybrid threshold | `hyb-thres = 0x271` = 625 | not settable from DT | gap |
| VREF | `vref-mv = 0x15e` = 350 mV | not settable from DT | gap |
| External PFET | `en-ext-pfet-sc-pro` | `qcom,external-pfet` | matches |
| Sync delays | `sync-dly-us 0x320`, `cons-sync-write-delay-us 1000`, `boost-duty-ns 0x1a` | defaults | to check |
| LAB/IBB | `qpnp-labibb-mode = "lcd"`, IBB 0xdc00/LAB 0xde00 | `&lab`/`&ibb` with `qcom,soft-start-us = <800>` | partly |

## 4. Stock behaviour

- Brightness arrives through the LED class at 0-255 and the driver scales to the 12-bit panel level; the low level the unit sits at right now (10/255) is a normal dim setting, not blanking.
- `bkl-trigger` binds the WLED to the framebuffer/DRM blank state, so off really is off.
- Swept 255 → 0 in steps with 2 s dwell (`evidence/stock-brightness-sweep-20261030.txt`): readable throughout, dark only at the very bottom (~1/255). Stock therefore has usable range essentially all the way down, which makes the prior port's 1200/4095 cutoff look like a Plasma/policy artefact rather than a limit of the WLED or the panel.

## 5. Mainline state

- Node enabled with per-string current and external PFET, which is the right direction.
- Boost limit and OVP are left at defaults above stock.
- There is no DT knob for `hyb-thres` or `vref` in 7.3, so the low-end behaviour cannot be tuned from the tree.
- No `default-brightness`/`max-brightness` set, so userspace decides.

## 6. Gap and plan

1. Add `qcom,current-boost-limit = <980>` and `qcom,ovp-millivolt = <29500>` so both match stock. Test: `grep` the driver's probe log and step brightness across the range while watching for `sc-irq` (interrupt 147).
2. Add `qcom,num-strings = <4>` and `qcom,enabled-strings = <0 1 2 3>` explicitly rather than relying on defaults.
3. Re-run the sweep (255 → 0, 2 s dwell) on mainline and compare against stock's measured result. Only if mainline cuts out early is a `hyb-thres` knob worth writing; stock needed none.
4. Set `max-brightness = <255>` and a sane `default-brightness` so the first boot is not full blast.
5. Verify blank/unblank: `bkl-trigger` should take the WLED to 0 and back with the DRM state; test with a 20× blank cycle and confirm no stuck-off.
6. Only after the range is stable, check whether CABC (`qcom,cabc`) is worth enabling; stock did not use it.

## 7. Risks

- Raising boost/OVP above stock (which the current defaults do) is the one thing the brief forbids — the LED string is 4 × 20 mA and the panel is a fixed load, so extra OVP means extra dissipation in the boost.
- Wrong string count or a wrong `enabled-strings` list leaves a string unlit and overloads the others.
- Hybrid-threshold experiments can leave the panel dark at low brightness with no error.
- LAB/IBB are shared with the panel rail; a WLED crash that leaves IBB up can leave the panel half-powered.

## 8. Open questions

- Is the ~1200 cliff the hybrid threshold, the panel's `bl-min-level`, or boost dropout? A sweep with `hyb-thres` varied would separate them.
- Does the mainline driver select `linear` or `exponential` dimming for this device, and does that match `dim-method = "linear"`?
- What does `qcom,modulator-sel` default to, and does it match 9600 kHz?
- Is CABC wanted for a mostly-static smart display at all?

## 9. Sources

- `../stock/stock-device-tree.dts:11201-11222`; `evidence/stock-backlight-state-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:348-353`; `drivers/video/backlight/qcom-wled.c` (property tables, `wled5_config_defaults`, OVP formula, `qcom,pmi8950-wled` binding at 1781).
- `../../ubuntu-thinksmart/README.md` (brightness 10 as "dark but alive"); `backlight/BRIEF.md`.
