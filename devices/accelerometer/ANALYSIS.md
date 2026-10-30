# Accelerometer — ThinkSmart View CD-18781Y

## 1. Summary

Bosch BMA253-class 3-axis accelerometer at I2C `0x18` on the bit-banged sensor bus (SDA GPIO 6, SCL GPIO 7), INT1 on GPIO 42. Stock does not touch it from APPS at all: the ADSP SSC owns it, announces it to Android as `BMA255 Accelerometer` (`sensor_id 0`, data type 1), and applies an identity axis map from the vendor `:platform QRD` block. Mainline 7.3 already has the `i2c-sensors` bus, the node (`bosch,bma253`, `bmc150-accel`, IRQ 42 `EDGE_RISING`, on `pm8953_l10`/`l6`) — the one real gap is that there is **no `mount-matrix`**, so the raw axes are whatever the PCB gives and any auto-rotation client has to guess signs. Our prior port worked around it with a daemon and four hard-coded sign assumptions.

## 2. Identity

- `compatible = "bosch,bma253"`, `reg = <0x18>`, `interrupts = <42 IRQ_TYPE_EDGE_RISING>`, `interrupt-names = "INT1"` (mainline DTS `accelerometer@18`).
- Address confirmed independently by the vendor SSC config: `# SSI SMGR Cfg 0 BMA253` → `i2c_bus 2`, `i2c_address 0x18`, `gpio1 42`, `sensor_id 0`, `data_type1 1`, `flags 0xD0`, `off_to_idle 3000` (`evidence/stock-sensor_def_qcomdev.conf.txt:1574-1596`).
- ADSP reports the part as **BMA255** (`dumpsys sensorservice`, `evidence/stock-dumpsys-sensorservice-20261030.txt`). BMA253 and BMA255 are the same register-compatible family and both are in `bmc150-accel-i2c`'s ID and OF-match tables, so the naming difference does not matter for the driver. It does matter for record-keeping: the silicon marking is not read out, only the ADSP's name for it. Treat "BMA253" as the board name, "BMA255" as what firmware called it, and do not try to distinguish them in software.
- No generic `bosch,bma2xx` fallback is needed; `bosch,bma253` is a first-class match (`drivers/iio/accel/bmc150-accel-i2c.c:251,267`).

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| Bus | ADSP bit-bang, SSC `i2c_bus 2` = BLSP `i2c_2` instance | `i2c-gpio` on GPIO 6 (SDA) / 7 (SCL), `GPIO_OPEN_DRAIN` | same pins, different master |
| Address | `0x18` | `0x18` | yes |
| Interrupt | `gpio1 = 42`, DRI, `flags 0xD0` | GPIO 42, `IRQ_TYPE_EDGE_RISING` | yes |
| Supplies | not in DT; ADSP side | `vdd = pm8953_l10`, `vddio = pm8953_l6` | inference only — see open questions |
| Mount matrix | identity axis map (`:platform QRD`: accel-x 1, -y 2, -z 3) | **absent** | gap |
| Live pin state | 6 and 7 are outputs, 2 mA, pull-up, unclaimed by Linux | claimed by `i2c-gpio` | expected difference (ADSP owns them on stock) |

Bus evidence: `../_inventory/ANALYSIS.md` §3 and `evidence/stock-sensor_def_qcomdev.conf.txt:1565-1575` (`I2C SDA_1 = 6`, `I2C SCL_1 = 7`, `ACCEL DRI = 42`).

Ambient reading while parked on the desk, for a later sign check: `x ≈ -0.18, y ≈ +9.60, z ≈ -3.06` m/s² (`evidence/stock-accel-readings-20261030.txt`).

## 4. Stock behaviour

- Driver is entirely on the DSP side. The SSC's own SLPI image fails to load on this build (`slpi_load_fw: pil get failed`), so the client attaches to the ADSP's SSCTL service instead. APPS sees nothing: no `/sys/bus/iio`, no I2C device, no kernel accelerometer driver in the GPL tree for this board.
- Discovery is by SSC config ID, not DT. `sens_default 1` means it is on by default; `off_to_idle 3000` ms and a DRI interrupt, so the ADSP sleeps the chip quickly when idle and uses the interrupt to wake it.
- Axis mapping comes from the `:platform QRD` block: `accel-x-axis 1`, `accel-y-axis 2`, `accel-z-axis 3` — identity, no swap, no inversion. Any rotation figure beyond that is applied in the Android framework, not by the sensor stack.
- Stock advertises a *second*, wakeup accelerometer instance (`… -Wakeup Secondary`, flags `0x1`) besides the non-wakeup primary. That is an Android power-management split, not extra hardware.
- `BMA255 Accelerometer/Temperature/Double-tap` also exposes temperature and double-tap through the ADSP; mainline `bmc150-accel` gives the same channels plus tap events, so nothing is lost.

## 5. Mainline state

- `i2c-sensors` bus: present, `i2c-gpio`, correct pins and open-drain flags, with `sensor_i2c_default` pinctrl.
- Node: complete — address, IRQ 42 rising, both supplies, `accel_int_default` pinctrl. Enabled.
- `bmc150-accel`: present in 7.3 with `bosch,bma253` in both tables.
- Missing: `mount-matrix`. Without it, `in_accel_*` axes follow the PCB, and every client (iio-sensor-proxy, Hyprland, our own daemon) must carry its own sign table. The prior port hard-coded `y<0 = normal`, `x>0 = left` in `rotation-daemon.py`, which is exactly the knowledge that belongs in the DT.
- Also missing: nothing else. Interrupt-mode operation works; the driver prefers IRQ when `INT1` is described.

## 6. Gap and plan

1. Derive the matrix on the target, not from guesswork: boot mainline, `cat /sys/bus/iio/devices/iio:deviceN/in_accel_{x,y,z}_raw` with the unit in each of the four upright orientations plus face-up, and record which axis/sign holds gravity.
2. Convert to a `mount-matrix` so that "upright, landscape, stand" reads as a clean `+Z`-up or Y-down baseline, then paste it into `accelerometer@18`. Test: `iio-sensor-proxy`'s `monitor-sensor` (or `iio_generic_buffer`) reports sane `Accelerometer orientation changed: normal/left-up/right-up/bottom-up` without our daemon.
3. Auto-rotation for Hyprland: `iio-sensor-proxy` plus a small listener that maps its orientation strings to `hyprctl keyword monitor …,transform N` (kscreen-doctor does not exist here). Test: rotate through all four, panel follows within ~1 s, no flapping at thresholds (add hysteresis).
4. Confirm the interrupt actually fires (`grep 42 /proc/interrupts` counter rises while moving the unit) so we are not silently falling back to polling.
5. Disable the driver's use of the ADSP side entirely — on mainline the SSC is not running, so the pins must be ours alone. Test: no `i2c` timeouts in `dmesg`, readings change when tilted.

## 7. Risks

- **Bus contention.** On stock the ADSP drives GPIO 6/7 as outputs. A mainline boot that still starts an SSC-like service would have two masters on the same wires. Keep the ADSP off (no remoteproc autoload for the sensors image) and check `dmesg` for `i2c-gpio` NAK storms.
- Bit-banged I2C at 2 mA drive with pull-ups on a shared PCB run is marginal; too-high a `i2c-gpio` clock will produce corrupt reads rather than clean failures. Start at 100 kHz and drop if needed.
- A wrong `mount-matrix` sign is worse than none: rotation will fight the user at exactly 180°.
- GPIO 42 is a wakeup-capable line on the PMIC side; leaving the interrupt edge wrong can produce wake storms during suspend.

## 8. Open questions

- Which rails actually power the sensor? The mainline node claims `pm8953_l10`/`l6`; stock declares none. Verify by regulator state while the ADSP has it open, or by continuity to the LDO test points.
- Is GPIO 42 shared with anything (the SSC `ACCEL DRI` entry is the only claimant seen)?
- Does this unit's part really answer at `0x18` as a BMA253, or is the ADSP name BMA255 literal? Read `CHIP_ID` (reg `0x00`, expect `0xFA` for BMA253/BMA255) once mainline owns the bus.
- Is a mount matrix already used by FelixKa's pmaports package that we should copy rather than re-derive?

## 9. Sources

- `evidence/stock-sensor_def_qcomdev.conf.txt` (vendor SSC config, pulled 2026-10-30), `evidence/stock-dumpsys-sensorservice-20261030.txt`, `evidence/stock-accel-readings-20261030.txt`, `evidence/stock-vendor-sensors-dir-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:72-96`; `drivers/iio/accel/bmc150-accel-i2c.c`.
- `../_inventory/ANALYSIS.md` §3; `../../ubuntu-thinksmart/sources/rotation-daemon.py` (prior sign assumptions).
- Stock DT has no accelerometer node (ADSP-only) — confirmed against `../stock/stock-device-tree.dts`. Boot-time SLPI load failure: `../stock/stock-boot-dmesg-20261030.txt`.
