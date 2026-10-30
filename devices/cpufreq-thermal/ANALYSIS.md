# CPU frequency and thermal — ThinkSmart View CD-18781Y

## 1. Summary

Eight Cortex-A53 cores on CPR4 closed-loop voltage scaling, with the usual TSENS bank and 22 stock thermal zones. This unit runs the top bin: `scaling_available_frequencies` is `652800 1036800 1401600 1689600 1804800` and it currently sits at 1.8 GHz. Stock's `thermal-engine.conf` is **empty** — it ships "File empty by default" — so there is no Lenovo thermal policy to reproduce, only Android's built-in defaults. Mainline has the full OPP table (including 1.8 GHz and the 2.2 GHz bins for other speed grades), `cpr4pd` with QFPROM fuse cells, and 16 zones with 80 °C passive / 100 °C critical trips. The work is to confirm the right speed bin is selected for this chip and to pick a thermal policy deliberately rather than by accident.

## 2. Identity

- SoC compatible `qcom,msm8953`, `qcom,apq8053` on the board.
- Live: governor `interactive`, `cpuinfo_max_freq = 1804800`, `scaling_cur_freq = 1804800`.
- OPP table (`msm8953.dtsi:290-400`): 614.4/652.8/844.8/1036.8/1228.8/1420.8/1612.8/**1804.8**/2016/2208 MHz with `opp-supported-hw` masks `0x4500/0xc5/0x45c5/0x85/0x80`; CPU nodes carry `nvmem-cells = <&cpu_speed_bin>`.
- CPR: `cpr4-ctrl@b018000`, `qcom,cpr4-msm8953-apss-regulator`, closed-loop, per-corner frequencies and temperature voltage adjustments (`stock-device-tree.dts:1720-1780`); mainline equivalent `qcom,msm8953-cpr4pd` bound to `&qfprom`.
- Thermal sensors: TSENS zones 5-19 (`tsens_tz_sensor1..15`), `xo_therm`, `pm8953_tz`, `pa_therm0/1`, `bms`, `battery`, `chg_temp`.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Frequencies | 652.8-1804.8 MHz, 5 steps | full table incl. 1804.8 and 2208 | mainline broader |
| Voltage control | CPR4 CL with temp compensation | `cpr4pd` + qfprom cells | equivalent mechanism |
| Speed bin | fuse-driven | `cpu_speed_bin` nvmem | yes |
| Governor | `interactive` | no governor chosen (schedutil default) | differs |
| Thermal trips | thermal-engine defaults, empty conf | 80 °C passive, 100 °C critical ×16 zones | mainline explicit |
| Cooling | thermal-engine + CPU freq cap | `cooling-device = <&cpuN>` per zone | equivalent intent |

## 4. Stock behaviour

- `thermal-engine` runs with defaults; the config that would override it is an empty two-line comment file (`evidence/stock-thermal-engine.conf`). So stock's real limits are compiled-in defaults, not board tuning.
- Idle temperatures right now: TSENS 29.6-31.6 °C, `pa_therm0` 82 (raw), `pm8953_tz` 31497 (millidegrees) — the unit is cold and idle.
- `interactive` with five steps; no `schedutil`. Android's framework drives the governor aggressively.
- CPR runs closed-loop against fused corner voltages, which is what makes 1.8 GHz safe on a passively cooled tablet.

## 5. Mainline state

- OPP table and CPR4PD exist; the GPU has its own OPP table with the same frequencies.
- Thermal zones exist for 16 sensors with passive and critical trips wired to CPU cooling devices — mainline is *more* conservative than stock (80 °C passive is early).
- No governor policy is chosen in the tree; that is a userspace decision (Arch defaults to `schedutil`).

## 6. Gap and plan

1. Verify the speed bin resolves to the 1.8 GHz OPP set and not a lower mask: boot, then check `scaling_available_frequencies` shows 1804800 and `opp-supported-hw` filtering has not dropped it.
2. Decide the governor: `schedutil` with an energy model is the sane default on a53; keep `interactive` only if `schedutil` misbehaves. Record the choice.
3. Raise the passive trip from 80 °C only after measuring. A first partial datapoint on stock: 8 busy loops took the SoC from `tsens 30.3 C` to `48.5 C` in 45 s, still at 1.8 GHz (`evidence/stock-load-sample-20261030.txt`); the full 10 minute run is still to do. If it throttles at 80 °C into unusability, move to 85-90 °C, keeping critical at 100 °C.
4. Record the load curve: temperature per minute, final steady-state clock, and whether the SoC survives 10 minutes without a TSENS critical trip.
5. Check the GPU interaction: while CPU throttling is active, confirm devfreq is not fighting it and the panel does not underrun.
6. Confirm suspend/idle temperatures with the screen off (see `../power-management/`).

## 7. Risks

- A wrong speed-bin mask can select voltages that are too low for 1.8 GHz and produce silent data corruption or random crashes.
- Trips that are too aggressive make the device unusable under load; too lax and a passive chassis can exceed 100 °C internally.
- Manual frequency pinning at 1.8 GHz on all cores with the GPU also loaded is the worst-case thermal state — test that combination specifically.
- `pa_therm` zones are raw ADC values, not degrees; misreading them gives nonsense limits.

## 8. Open questions

- Which `opp-supported-hw` mask corresponds to this chip's fuse level, and does it include 1804800?
- What are Android's built-in thermal-engine defaults, since the conf is empty?
- Does the passive chassis actually sustain 1.8 GHz, or is that only a burst clock?
- Are `pa_therm0/1` meaningful without a PA (no modem) — do they track the SoC or sit at a constant?

## 9. Sources

- `evidence/stock-thermal-cpufreq-20261030.txt`, `evidence/stock-thermal-engine.conf`; live `cpufreq` sysfs.
- `../stock/stock-device-tree.dts:1720-1780` (CPR4); `msm8953.dtsi` OPP table and `thermal-zones:3215-3300`.
- Mainline `drivers/pmdomain/qcom/cpr4pd.c:538`.
- `cpufreq-thermal/BRIEF.md`.
