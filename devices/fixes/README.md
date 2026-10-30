# DTS fixes from the device analyses

One patch, `0001-dts-known-gaps-from-the-device-analyses.patch`, against
`arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` on `barni2000/7.3/develop`.

Verified to apply cleanly (`patch --dry-run`) against that branch's file. **Nothing here is built or flashed yet.**

Each hunk comes from a specific analysis; the reasoning and tests are there, not repeated here.

| Hunk | Change | From | Why |
| --- | --- | --- | --- |
| gpio-keys comment | correct the "hardware mute switch" claim | `privacy-switches/ANALYSIS.md` §5 | Measured: the only switch fitted is the lens cover and it does not mute the mic. |
| panel `compatible` | `lenovo,cd-18781y-panel` → `lenovo,cd-18781y-ft8201` | `display-panel/ANALYSIS.md` §5 | The DTS string matches no driver; the FT8201 driver's line even carries `// FIXME`. This unit is the FocalTech variant. |
| WLED | `current-boost-limit = <980>`, `ovp-millivolt = <29500>`, `enabled-strings = <0 1 2 3>` (which also sets the string count; setting both would warn) | `backlight/ANALYSIS.md` §6 | Driver defaults are 1260 mA and 32.5 V, both *above* stock's 980 mA / 29.5 V. The brief says do not exceed stock. |
| VCNL4200 | add `vdd-supply = <&pm8953_l10>`, `vddio-supply = <&pm8953_l6>` | `proximity-light/ANALYSIS.md` §5 | `devm_regulator_bulk_get` fails on a missing supply, so the node cannot probe at all today. Node stays `disabled` until the LED-current patch lands. |
| USB | `dr_mode = "peripheral"` | `usb/ANALYSIS.md` §6 | dwc3 defaults to OTG with nothing able to detect role. |
| FT8201 touch | `status = "okay"` + `wakeup-source` | `touch/ANALYSIS.md` §6 | Both touch nodes are disabled and nothing selects one; this unit ACKs at `0x38`. |

## Applying

```sh
cd $KERNEL            # a 7.3/develop checkout
git apply --check devices/fixes/0001-*.patch && git apply devices/fixes/0001-*.patch
```

## Still needs code, not DT

These are identified but cannot be fixed in a patch of this shape:

- `avdd` is never requested by the panel driver (GPIO 100 rail stays off) — `display-panel/`.
- FT8201 slot cap 10 vs 5 real slots — `touch/`.
- VCNL4200: LED current and multi-pulse need a driver property; the node must stay disabled until then — the hazard is binding.
- `ath10k` rekey: source fix, unfixed upstream on 7.3 as well — `wifi/`.
- TAS5782M has no driver in the tree at all — `speaker/`.

## Ordering caution

Do not enable the VCNL4200 hunk's `status` early: with the unmodified `vcnl4000` driver it runs the IR LED at 120 mA × 8 pulses and pins it on whenever proximity events are active.
