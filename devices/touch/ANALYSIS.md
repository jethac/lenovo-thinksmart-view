# Touchscreen — ThinkSmart View CD-18781Y

## 1. Summary

This unit is the FocalTech FT8201 TDDI variant: `IC ID 0x8201` reported by the stock driver, `fts_ts` bound at I2C `0x38`, five touch slots, 800x1280, IRQ 232 on GPIO 65, reset GPIO 64. It is the same die as the panel, so its reset is the panel's reset. Mainline provides `focaltech,ft8201` in `edt-ft5x06.c` and a full node — but **both touch nodes are `disabled` and nothing enables either**, so touch cannot work at all today. Beyond that the gaps are a 10-versus-5 slot mismatch, stock-only features (glove, cover, charger, firmware update) that mainline lacks, and the wake-on-touch question, which is entangled with panel power.

## 2. Identity

- `3-0038`, `name = fts`, `compatible = "focaltech,fts"` on stock; mainline `focaltech,ft8201` → `edt_ft5x06.c` (`edt_ft8201_data`, `max_support_points = 10`, match at line 1513).
- Stock driver banner: `Driver Ver:Focaltech V3.0 20190102`, `IC ID:0x8201`, `Resolution:(0,0)~(800,1280)`, `Max Touchs:5`, `reset gpio:64,int gpio:65,irq:232` (`evidence/stock-fts-state-20261030.txt`).
- Firmware version `15`, `fts_boot_mode = "tp is in boot mode"`.
- Input device `fts_ts`: `KEY_F1`, `BTN_TOUCH`, `ABS_MT_SLOT` 0-4, `ABS_MT_POSITION_X` 0-800, `_Y` 0-1280, `_PRESSURE`, `_TRACKING_ID`, `INPUT_PROP_DIRECT`. No `SW_*`, no gesture keys.
- Same die as the panel, which stock calls `boyift8201_800p_video` (see `../display-panel/ANALYSIS.md`).

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Bus / address | `i2c_3` @ `0x38` | same | yes |
| IRQ | GPIO 65, irq 232 | `interrupt-parent = <&tlmm>`, `interrupts = <65 IRQ_TYPE_EDGE_FALLING>` | yes |
| Reset | GPIO 64 | `reset-gpios = <&tlmm 64 GPIO_ACTIVE_LOW>` | yes |
| Supplies | `vdd_ana = l10`, `vcc_i2c = l6` (GPL `gt9xx`/`fts` sibling nodes) | `iovcc-supply = l6`, `vcc-supply = l10` | naming differs, rails same |
| pinctrl | — | `ts_reset_default`/`ts_int_default` (8 mA, pull-up) plus `_sleep` states | supplied on 7.3 |
| Node state | probes | **`disabled`** | gap |
| Panel coupling | same silicon as panel | not modelled | gap |

## 4. Stock behaviour

- Vendor `fts_ts` driver with a large sysfs surface: `fts_glove_mode` (reg 0xC0), `fts_cover_mode` (reg 0xC1), `fts_charger_mode` (reg 0x8B), `fts_fw_version`, `fts_upgrade_bin`, `fts_force_upgrade`, `fts_test`, `fts_dump_reg`, `fts_rw_reg`, `fts_hw_reset`, `fts_log_level`, `fts_irq`.
- Firmware is flashed through sysfs (`fts_upgrade_bin`); there is no separate firmware file in `/vendor/firmware`, so the image is embedded in the vendor driver or pushed by a tool.
- Glove and cover modes are FocalTech register features: glove raises sensitivity, cover disables the digitiser. Charger mode exists because a charger injects noise.
- Boot log shows the discrimination directly: the Himax driver probes first and fails (`gpio_rst value is not valid`, `gpio_rst=-2`, `i2c_write_block retry over 10`, `test i2c failed` — its reset GPIO is commented out in the stock DT), then FocalTech probes and succeeds (`fts_ts_probe ... successfully`) at `0x38` (`../stock/stock-boot-dmesg-20261030.txt:71-92,140-168`). So the variant is decided by who ACKs, and the Himax node on this unit is broken by its own DT.
- Touch reports through `ABS_MT_*` with `BTN_TOUCH`; `KEY_F1` is used for a vendor gesture path only.

## 5. Mainline state

- `edt-ft5x06` handles `focaltech,ft8201`; it is a generic EDT driver with `threshold` and `gain` DT knobs and a `max_support_points` cap of 10 for this part.
- The node is complete but disabled; nothing selects between `ft8201_ts` and `hx83100a_ts`.
- No gesture support and no wakeup handling in the driver; `wakeup-source` is not read.
- Reset is shared with the panel driver, so `display-panel`'s `unprepare` assertion resets touch too, and neither driver knows about the other.

## 6. Gap and plan

1. Enable the correct node for this unit. Simplest correct answer: enable `ft8201_ts` in this DTS (this unit is known to be FT8201) and leave `hx83100a_ts` disabled with a comment; select properly later if the second variant matters to whoever else flashes this image.
2. Set `max-touch-number`/cap to 5 to match the panel's real limit, either through `max_support_points` chip data or a DT property (small driver patch).
3. Coordinate sanity: verify that `touchscreen-size-x/y` 800/1280 holds through a rotation transform, i.e. that rotation is handled in the compositor and not by swapping the axes.
4. Wake on touch: test whether the digitiser still reports interrupts with the panel `unprepare`d (rails down). If not, keep `vcc`/`iovcc` alive across blank and only reset on long blanks; if the panel must stay powered, say so.
5. Optional stock features: expose glove/cover via a small debugfs or DT default if they matter; skip charger mode (no battery/charger).
6. Test: all five points simultaneously, corner and edge accuracy, drag with no jumps, then blank/unblank and confirm touch recovers without a compositor restart.

## 7. Risks

- Enabling the wrong variant puts both drivers on the same IRQ/reset and can wedge the TDDI — note the Himax node's own reset GPIO is missing in stock, so enabling it as-is cannot work.
- Asserting reset from the panel driver while touch holds the bus leaves touch dead until its next open — the same failure mode already reported as "touch cannot wake the screen".
- Reading vendor registers (`fts_rw_reg`, `fts_upgrade_bin`) with a mismatched firmware can leave the chip in boot mode.
- Coordinate range differs between orientations; a wrong transform makes the digitiser unusable rather than merely offset.

## 8. Open questions

- Is `tp is in boot mode` the normal steady state or does it mean firmware failed to load on stock?
- Does the FT8201 keep reporting with its rails at 0 V, or does wake-on-touch require keeping it powered?
- Where does the stock firmware image come from if it is not in `/vendor/firmware`?
- Is 10 slots real for FT8201, or is 5 the hardware truth and 10 only a driver cap?

## 9. Sources

- Live 2026-10-30: `/sys/bus/i2c/devices/3-0038/*`, `getevent -lp /dev/input/event1`; `evidence/stock-fts-state-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:271-299`; `drivers/input/touchscreen/edt-ft5x06.c:1470-1520,960-975`.
- `../_inventory/ANALYSIS.md` (probe order), `../display-panel/ANALYSIS.md` (shared reset); `touch/BRIEF.md`.
