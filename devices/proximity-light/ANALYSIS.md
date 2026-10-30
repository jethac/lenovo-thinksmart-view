# Proximity and ambient light — ThinkSmart View CD-18781Y

## 1. Summary

Vishay VCNL4200 at I2C `0x51` on the bit-banged sensor bus, INT on GPIO 43, answering device ID `0x1058`. Stock reaches it only through the ADSP SSC, which advertises proximity as a **wakeup** sensor and ambient light as non-wakeup — so "hand near screen wakes it" is a designed, validated function, not an accident. Mainline 7.3 has the node but leaves it `disabled`, and the warning in the DTS is real: the upstream driver programs the IR LED at 120 mA with 8 multi-pulses and has no DT or sysfs control over current or pulse count. There is a second, sharper problem: the node has no supplies at all, so simply flipping it to `okay` makes the driver fail to probe. The hazard is manageable, but only with a driver-side change plus screen-state gating.

## 2. Identity

- `compatible = "vishay,vcnl4200"`, `reg = <0x51>`, `interrupts = <43 IRQ_TYPE_EDGE_RISING>`, `interrupt-names = "INT1"` (mainline DTS `light-sensor@51`, `status = "disabled"`).
- Confirmed twice from stock: SSC config `# SSI SMGR Cfg 1: VCNL4200` — `i2c_bus 2`, `i2c_address 0x51`, `gpio1 43`, `sensor_id 40`, `data_type1 5` (light), `data_type2 6` (proximity), `flags 0x80`, `reg_group_id 1040` (`evidence/stock-sensor_def_qcomdev.conf.txt:1585-1600`); and the runtime-encoded registry record at offset 5972 of `/persist/sensors/sns.reg`, which carries the same bus/address/GPIO/type tuple (`evidence/stock-persist-sns.reg-20261030.txt`).
- Device identity is checked by the driver itself: `VCNL4200_PROD_ID 0x58` at register `0x0e`, and the full 16-bit read is `0x1058` (ID 0x58, revision 0x0), which is what the prior port's daemon used as a health check.
- Stock sensor list names it `VCNL4200 PRX` / `VCNL4200 ALS` with vendor string `Capella` (`evidence/stock-dumpsys-sensorservice-20261030.txt`) — the ADSP driver vendor, not Vishay.

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| Bus | SSC `i2c_bus 2` → BLSP `i2c_2` pins | `i2c-gpio`, SDA 6 / SCL 7, open drain | same pins |
| Address | `0x51` | `0x51` | yes |
| Interrupt | `gpio1 = 43` (ALS/PRX INT), `flags 0x80` | GPIO 43, `IRQ_TYPE_EDGE_RISING` | yes |
| Supplies | not in DT (ADSP side) | **none declared** | gap — probe fails |
| `vled` (IR LED supply) | not declared | not declared | both silent |
| LED current | 200 mA, single pulse | 120 mA, 8 pulses, hard-coded | disagrees (see §5) |
| Node state | active via SSC | `disabled` | expected difference |

Pins 6/7 are `I2C SDA_1` / `I2C SCL_1` and GPIO 43 is `ALS/PRX INT` in the SSC GPIO map (`evidence/stock-sensor_def_qcomdev.conf.txt:1565-1575`).

## 4. Stock behaviour

- Entirely DSP-side (over the ADSP: the SSC's SLPI image fails to load on this build); no APPS driver, no I2C device on stock. `sens_default 0` (off until requested), `off_to_idle 1000` ms.
- Proximity is flagged `wakeUp` with `minRate 0.02 Hz` and an `on-change` reporting mode: the SSC only reports a transition, so the LED duty is low when nothing changes. Ambient light is non-wakeup by default and has a separate wakeup secondary instance.
- Register settings, captured from the prior port's validated daemon rather than read out of the ADSP: `PS_CONF1 = 0xCA` → `PS_IT = 11` (4T, longest integration), `PS_DUTY = 00` (1/40, lowest duty), `PS_PERS = 10`, `PS_SD = 0`; `PS_MS = 0x0700` → `LED_I = 111` (200 mA), `MPS = 00` (single pulse). Proximity threshold ≈ 50 counts; ambient is 3-11 counts, a hand at 30 cm is 30-80.
- Practical policy: LED on and sampled only while the screen is off; disabled entirely while the screen is on (prior `vcnl4200-proximity-daemon.py`). Energy per measurement is therefore one 200 mA pulse, at 1/40 duty, 2 Hz.
- **Wake on approach does not happen on stock.** Screen off (`Dozing`, display OFF), hand waved over the sensor: nothing. No PRX entries appear in `Recent Sensor events` at all, i.e. no client is subscribed — the hardware supports the function but this build never uses it. `evidence/stock-proximity-wake-test-20261030.txt`.

## 5. Mainline state — and why the node is disabled

What the driver does in 7.3 (`drivers/iio/light/vcnl4000.c`):

- `vcnl4200_init()` writes `VCNL4040_CONF3_PS_SAMPLE_16BITS` = `MPS = 3` (**8 multi-pulses**) and `LED_I = 3` (**120 mA**) into `PS_CONF3`/`PS_MS`. That is `8 × 120 = 960 mA·pulse` per sample against stock's `1 × 200 = 200` — **4.8× more IR energy per measurement**, and stock's duty cycle is inherited unchanged.
- Neither figure is settable: no DT property, no sysfs attribute. `PS_DUTY` is left at reset (`1/40`).
- Runtime PM exists: `VCNL4000_SLEEP_DELAY_MS = 2000`, autosuspend, and suspend sets `PS_SD` (shutdown) so the LED goes off. Good.
- But `vcnl4200_set_power_state()` returns early when interrupts are enabled: *"Do not power down if interrupts are enabled"*. Turning on the proximity **event** interface (`events/in_proximity_thresh_either_en`) pins the device resumed and leaves the LED firing forever at 120 mA × 8 pulses. That is the exact failure the DTS warning describes.
- Supplies: probe uses `devm_regulator_bulk_get_enable(dev, 3, {"vdd","vio","vled"})`, and `_regulator_bulk_get()` returns an error for any missing supply. With no `vdd`/`vddio` in the node, the driver never binds, so "disable it" currently protects nothing that enabling would not also break. Enabling without supplies is a no-op, not a burn.

## 6. Gap and plan

1. Add the supplies the driver expects before anything else: `vdd = <&pm8953_l10>`, `vddio = <&pm8953_l6>` (same rails the accelerometer on the same bus uses), and `vled` only if a separate LED rail exists. Test: with the node still disabled nothing changes; enabling it now probes and logs the device ID.
2. Driver change: make LED current and multi-pulse count DT properties (`vishay,led-current-microamp`, `vishay,multi-pulse`) with conservative defaults, and use 1 pulse / 120 mA for this board. Test: probe log plus an actual register read showing `MPS = 0`, `LED_I != 3`.
3. Driver change: do not hold the LED on for interrupt operation — re-arm the threshold and let runtime PM suspend between transitions, or move sampling to a periodic trigger. Test: leave proximity events enabled for 10 minutes and measure current/temperature.
4. Keep proximity out of the always-on path: enable the channel only while the panel is blanked. Test: `cat /sys/class/backlight/*/brightness`, blank the screen, confirm `PS_SD` clears only then.
5. Ambient light for auto-brightness: ALS works at the same settings; drive a brightness curve from `in_illuminance_*` and fold it into whatever the idle/backlight daemon already does.
6. Wake-on-approach: mainline maps this to the proximity event; wire it to unblank, with the debounce and cooldown the prior daemon used (threshold 50 counts, 1-3 consecutive reads, 10 s cooldown).

## 7. Risks (binding)

- **The IR LED.** At 8 pulses × 120 mA continuously it runs noticeably hot. Never enable proximity events on a node without the MPS change, and never leave the LED on with the panel up.
- **Probe failure masquerading as success.** Missing supplies mean the node can sit `okay` with no device behind it; check `dmesg` and the IIO directory, not the DT.
- **Burn-in of the LED** if current is pushed above 200 mA or duty above 1/10 for long periods.
- **Retained state.** LED current and pulse settings live in the sensor's registers; a warm reboot with the driver patched down but the previous run left at 8 pulses will show the old heat until re-probed. Re-init explicitly.
- Bus contention with the ADSP, same as the accelerometer: keep the SSC image unloaded.

## 8. Open questions

- Does this board actually have a separate `vled` rail, or is the LED fed from `vdd`? Decides whether `vled` belongs in the DT.
- Note the SSC/SLPI loader fails on stock, so anything the SSC would have configured comes from the ADSP path instead.
- What threshold/persistence does the ADSP actually use in production? `reg_group_id 1040` exists in `sns.reg` but the payload is packed binary and unnamed; threshold 50 comes from the previous port, not from stock.
- Would upstream accept `vishay,multi-pulse` and a "don't pin the LED on for interrupts" fix? The MPS property is a small, obviously-correct addition.
- Is the ALS calibration (lux/`ulux_step`) still right once the LED settings change?

## 9. Sources

- `evidence/stock-sensor_def_qcomdev.conf.txt` (VCNL block, SSC GPIO map), `evidence/stock-persist-sns.reg-20261030.txt`, `evidence/stock-dumpsys-sensorservice-20261030.txt`, `evidence/stock-vcnl-live-readings-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:98-116`; `drivers/iio/light/vcnl4000.c` (`vcnl4200_init`, `vcnl4200_set_power_state`, `VCNL4000_SLEEP_DELAY_MS`, probe regulator list); `drivers/regulator/core.c` `_regulator_bulk_get`.
- `../../ubuntu-thinksmart/README.md` "vcnl4200-proximity-daemon" section and `sources/vcnl4200-proximity-daemon.py` (register values, thresholds, health check).
- `../stock/stock-boot-dmesg-20261030.txt` (SLPI load failure and the ADSP SSCTL attach); `../_inventory/ANALYSIS.md` §3; `proximity-light/BRIEF.md`.
