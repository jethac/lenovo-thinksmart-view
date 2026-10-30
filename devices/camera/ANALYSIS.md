# Camera — ThinkSmart View CD-18781Y

## 1. Summary

Front camera, Samsung S5KC505A on CCI master 0, bound as `v4l-subdev18`. Lenovo's GPL tree contains **no camera sensor drivers at all** — `camera_v2/sensor/` holds only the framework — so the driver is prebuilt (`/vendor/lib/libmmcamera_s5kc505a.so`) and everything about the part has to come out of that binary. The first RE pass is done: CCI address `0x36`, chip-ID register `0x0000` with value `0x5034`, and the exposure register map. Mainline has the SoC side (CAMSS, CSIPHY, CSID, CCI) but zero board nodes. This is the largest single piece of work in the project and needs reverse engineering before it needs DT.

## 2. Identity

- Bound V4L sub-device `s5kc505a` (`v4l-subdev18`), sensor library `libmmcamera_s5kc505a.so` (583 912 B, pulled to `evidence/`), tuning `libchromatix_s5kc505a_default_preview_3a.so` (66 740 B) plus `…_cpp_liveshot.so` and `…_default_video.so`.
- Stock DT slot 0 is the front sensor: `qcom,sensor-position = <0x01>`, `qcom,mount-angle = <0x10e>` (270), `qcom,csiphy-sd-index = <0>`, `qcom,csid-sd-index = <0>`, `qcom,cci-master = <0>` (`../stock/stock-device-tree.dts:5608-5642`). Slot 2 is also enabled; slot 1 is disabled.
- Other sensors Lenovo shipped tuning for: `ov5693`, `s5k4e8` — so a swapped module on another unit is plausible; this unit's bound sensor is the S5KC505A.
- The library is stripped to two exported helpers plus a bundled libunwind; the sensor API is a small self-contained block at `0x107cc`-`0x10bb0` and the rest is binary data. Mode tables and B-frames of register init therefore need disassembly, not strings.

## 3. Wiring (stock slot 0 — the only board-specific source)

| Item | Stock value | Notes |
| --- | --- | --- |
| MCLK | GPIO 26, `qcom,clock-rates = <0x16e3600>` | 24 MHz |
| Reset | GPIO 40, `qcom,gpio-reset` | |
| Standby (PWDN) | GPIO 39, `qcom,gpio-standby` | |
| VDIG | GPIO 118, rail `pm8953_l2`, 1 200 000 µV | 1.2 V — **do not guess** |
| VANA | GPIO 119, rail `pm8953_l17`, 2 850 000 µV | 2.85 V |
| VIO | rail `pm8953_l6`, 1 800 000 µV | 1.8 V |
| CCI slave address | **`0x36`**, master 0 — recovered from the library, constant across three Lenovo sensor libs | from RE, see §5 |
| Chip-ID | reg `0x0000`, expected `0x5034` | prove on the wire |
| Vendor sensor id | `0x6e` (110) | framework bookkeeping |
| CSIPHY / CSID | PHY 0 / CSID 0 | |
| Actuator slot | `qcom,actuator-src` present | fixed focus? open question |
| EEPROM slot | `qcom,eeprom-src` present | OTP available |

Mainline has no board camera node, so there is nothing to compare against yet.

## 4. Stock behaviour

- Vendor `msm_sensor` framework: `msm_sensor_init`, per-sensor library, `msm_actuator`, `msm_eeprom`, `msm_camera_flash` (torch0/1), `msm_ispif`, `vfe`, `cpp`. The library is loaded by `msm_sensor_init` and owns the register tables.
- Tuning lives in separate chromatix libraries (`3a`, `cpp_liveshot`, `default_video`), not in the sensor library.
- Capture is via `video32`/`video33` with the classic `msm-config`/`msm-sensor` control devices; `media-ctl` is not present on stock.
- Lens cover switch reports state only (see `../privacy-switches/`); nothing in the DT ties GPIO 87 to sensor power.

### Reverse-engineered internals (2026-10-30)

The library has been disassembled and decompiled (details and method in `evidence/re-findings-20261030.md`, function dump in `evidence/s5kc505a-ghidra-functions-20261030.txt`):

- **Slave address `0x36`** at `sensor_slave_info+0xb9`, identical in the OV5693 and S5K4E8 libraries while every per-sensor field differs, and consistent with the OV5693 address already used in the mainline node.
- **Chip-ID check**: register `0x0000`, expected `0x5034`, mask unused. Samsung sensors answer the chip ID at 0.
- **Exposure register map**: `0x0340` frame length, `0x0202/0x0203` coarse integration, `0x020e/0x020f` long exposure, `0x0210`-`0x0215` per-channel gain. All 16-bit, written high byte first.
- **Gain encoding**: 10-bit field, clamped `0x20`-`0x1ff`, i.e. 1x = 32 with a 16x top in 1/32 steps.
- **Mode table located**: five register blocks in `.data` at `0x50044`, `0x54054`, `0x58054`, `0x5c064`, `0x60074`, each indexed by `0x034e` and starting with the Samsung readout registers `0x0340`-`0x0343`. Geometry semantics are not yet settled — no 800 or 1280 literal exists anywhere in the library.
- Still missing: what those geometry values mean, MIPI lane count and link frequency, and the power-up sequence in `sensor_init`.

## 5. Mainline state

- `camss@1b00020` and the CSIPHY/CSID/CCI blocks exist in `msm8953.dtsi`.
- No `cam0` node, no CSI2 endpoint, no sensor, no supplies.
- FelixKa's `mipi-ccs` placeholder and rickx's OV5693 node are both wrong for this unit.
- libcamera has a CAMSS pipeline handler (simple pipeline, software ISP); whether it covers msm8953 well enough is unproven.

## 6. Gap and plan

1. **Finish the reverse engineering** (Ghidra): the address and exposure map are done; still needed are the mode table, lane count, link frequency and power-up order. `sensor_init` is the function holding the register sequences.
2. Decide whether S5KC505A is CCS-compliant. It is a Samsung ISOCELL part and almost certainly **not**, so plan for a real driver rather than `ccs`.
3. Write a minimal driver: probe, power up in the documented order, one mode, streaming, exposure/gain, test pattern. `s5k5baf`/`s5k4ecgx` in mainline are the closest style references.
4. Add the DT node with the exact stock voltages, GPIOs and 24 MHz MCLK; wire to CSIPHY 0 / CSID 0 and libcamera's simple pipeline.
5. Stills and preview through libcamera; orientation fixed by `rotation` (270) rather than by userspace.
6. Read the EEPROM (lens shading/colour) if the OTP is actually populated; otherwise document that it is empty.
7. Respect the lens cover: refuse to start a stream when it is closed.

## 7. Risks

- **Regulator values**: 1.2 V VDIG and 2.85 V VANA are from this board's DT. A wrong VDIG will damage the sensor.
- Power-up order (VIO/VANA/VDIG, MCLK, reset release, standby) is critical; wrong order can latch the sensor or leave the MIPI PHY in a bad state.
- CSIPHY power on CAMSS is shared with other users on some SoCs; enabling the camera without the right CSIPHY clock/PHY settings can hang the CAMSS block.
- Reversing a stripped binary invites misreading a table offset; validate every recovered value by watching the sensor answer on CCI.

## 8. Open questions

- What is the CCI address? (RE)
- Is there a VCM/autofocus actuator populated, or is the camera fixed focus?
- Is the EEPROM/OTP populated with calibration?
- Does libcamera's simple pipeline handle the register/format split the S5KC505A needs?
- Is CAMSS for msm8953 exercised by any upstream device at all?

## 9. Sources

- `evidence/libmmcamera_s5kc505a.so`, `evidence/libchromatix_s5kc505a_default_preview_3a.so`, `evidence/stock-camera-nodes-libs-20261030.txt`.
- `../stock/stock-device-tree.dts:5608-5642`; GPL `apq8053-camera-sensor-dragon.dtsi` (`_inventory/evidence/gpl-dts-*`).
- GPL `drivers/media/platform/msm/camera_v2/sensor/` (framework only).
- `../../ubuntu-thinksmart/research/camera/`; `camera/BRIEF.md`.
