# Hardware inventory — ThinkSmart View CD-18781Y

Captured 2026-10-30 from the live stock device (root adb, read-only) and from the stock device tree.

## 1. Summary

The board is an APQ8053-lite smart display. Everything the README lists is present **except** that the two "sensors" (BMA253 accelerometer, VCNL4200 prox/light) do not appear on any bus the APPS kernel can see: they are behind the ADSP/SSC (`qcom,msm-ssc-sensors`, `CONFIG_SENSORS_SSC=y`), reached over a TrustZone-protected BLSP bus. Everything else is normal and enumerable: DSI panel + PMI8950 WLED + LAB/IBB, three mutually exclusive touch controllers on `i2c_3`, TAS5782M on `i2c_1`, camera on CAMSS/CCI, QCA9379 Wi-Fi on `sdhc_2`, QCA BT on `blsp2_uart0`, RGB status LEDs on PMI8950 MPPs, two torch LEDs, FM (`radio-iris`, WCNSS-based). The exact Lenovo board file is `apq8053-lite-dragon-v2.0.dtsi` (board-id match). The single biggest blocker for the port is the sensor path: mainline has no SSC, so the BMA253 and VCNL4200 must be moved onto a bus mainline can own.

## 2. Identity

- Live DT: `model = "Qualcomm Technologies, Inc. APQ8053 Lite DragonBoard V2.0"`, `compatible = "qcom,apq8053-lite-dragonboard","qcom,apq8053","qcom,dragonboard"`, `qcom,board-id = <0x1010520 0x0>`.
- **Exact source match**: Lenovo GPL `arch/arm/boot/dts/qcom/apq8053-lite-dragon-v2.0.dts` carries the identical model, compatible and `qcom,board-id = <0x01010520 0>`; the board-specific nodes are in `apq8053-lite-dragon-v2.0.dtsi` (evidence: `evidence/gpl-dts-apq8053-lite-dragon-v2.0-*`). This is the authoritative wiring reference for every other brief.
- Sibling board IDs in the same tree, none of which is this unit: `0x0102000a` (v1.0), `0x0103010A` (ext-codec v2.0).
- Vendor fingerprint (live): `Lenovo/CD-18781Y/CD-18781Y:8.1.0/OPM1.171019.026/penghu06021417:user/release-keys`.
- The GPL tree builds this as a **32-bit ARM** target (`arch/arm/boot/dts/...`, `zImage-dtb`); there is no arm64 copy of the Lenovo board file. Mainline is aarch64, so every node has to be re-expressed.

## 3. Wiring

Source: `evidence/stock-sysfs-buses-20261030.txt`.

#### I2C (BLSP)
| Bus | Addr | Driver / name | Device dir | Maps to |
| --- | --- | --- | --- | --- |
| i2c-1 (`78b5000`, BLSP1 QUP5) | 0x49 | `ti,tas5782m` | `1-0049` | `speaker/` |
| i2c-3 (`78b7000`, BLSP2 QUP1) | 0x14 | `goodix,gt9xx` | `3-0014` | `touch/` (rev A candidate, DT status disabled) |
| i2c-3 | 0x38 | `focaltech,fts` | `3-0038` | `touch/` |
| i2c-3 | 0x48 | `himax,hxcommon` | `3-0048` | `touch/` |

All three touch controllers are enabled in the GPL DT on the same bus and same IRQ, so they are alternative population options, not simultaneous devices. `gt9xx-i2c@14` has an explicit `status = "okay"` in GPL; the mainline DTS also carries all three. Live, **all three probed and bound** — so the addresses overlap only in DT, and the deciding factor is which chip ACKs. The bound input device on this unit is `fts_ts` (FocalTech FT8201, addr 0x38, IRQ GPIO 65, reset GPIO 64). That settles which touch revision `HUA0BMNX` is.

Sensors are **not on any BLSP I2C bus** and not on `i2c_3` either. They are ADSP devices, reached by the SSC client: the GPL defconfig sets `CONFIG_SENSORS_SSC=y` and the DT has `qcom,msm-ssc-sensors`, but the SLPI image fails to load on this build and the client attaches to the ADSP instead (boot log above).

**Confirmed by vendor config:** `/vendor/etc/sensors/sensor_def_qcomdev.conf` has `I2C SDA_1 = 6`, `I2C SCL_1 = 7`, `# SSI SMGR Cfg 0 BMA253` at `i2c_bus 2` / `0x18` / `gpio1 42`, and `# SSI SMGR Cfg 1: VCNL4200` at `i2c_bus 2` / `0x51` / `gpio1 43`. So the SSC's "bus 2" is the `i2c_2` pin pair, bit-banged by the ADSP. **Candidate sensor bus (observed):** GPIO 6 and GPIO 7 are the `blsp_i2c2` pin pair (`i2c_2_active` mux `function = "blsp_i2c2"`, pins `gpio6`,`gpio7`). On the live unit `i2c_2` is disabled in Linux while `debugfs/gpio` shows both pins as **outputs** (`gpio6: out 3`, `gpio7: out 3`, 2 mA, pull-up) — i.e. someone other than the APPS I2C driver is toggling them. Together with the vendor config this is conclusive that the ADSP bit-bangs the BMA253/VCNL4200 on GPIO 6/7 (bus 2 = `i2c_2` pins, and nothing else in the tree claims them). That maps directly to the `accelerometer` and `proximity-light` briefs: mainline can take those pins as `i2c-gpio` (or enable `blsp_i2c2`) once the ADSP is out of the picture.

i2c-2 (`78b6000`) in GPL: `status = "disabled"`, as are `spi_3` and `i2c_5`. `blsp1_uart0` is the debug console; `blsp2_uart0` is enabled for BT.

#### Live pinmux ownership (evidence: `evidence/stock-debugfs-pinmux-20261030.txt`)
Claimed TLMM pins on stock, which is a direct map of what hardware actually uses:

| Pins | Owner | Meaning |
| --- | --- | --- |
| 2,3 | `78b5000.i2c` blsp_i2c1 | speaker amp bus |
| 10,11 | `78b7000.i2c` **function gpio** | touch bus — note the live kernel has these muxed as plain GPIO, not `blsp_i2c3` (see open question) |
| 16-19 | `7aef000.uart` blsp_uart5 | BT HCI UART |
| 24 | mdss_dsi_ctrl0 mdp_vsync | panel TE |
| 29-32 | `1b0c000.qcom,cci` cci_i2c | camera CCI |
| 61 | mdss_dsi_ctrl0 | panel reset |
| 64,65 | pinctrl hog | touch reset / IRQ |
| 68 | `1-0049` (TAS5782M) | amp enable |
| 75,77 | `7864900.sdhci` | Wi-Fi SDIO power/CLK-req |
| 76 | pinctrl hog | BT_EN |
| 85,86,87 | `soc:gpio_keys` | vol_up / mute (unpopulated) / camera shutter |
| 88-93 | `c051000.sound` pri_mi2s | amp I2S |
| 100 | mdss_dsi_ctrl0 | panel ext_vdd / bklight-en |
| 135-138 | `c051000.sound` sec_mi2s | DMIC |
| 139 | qpnp-typec | SS mux |

#### Bus state: SDIO
- `mmc1:0001:1`, vendor 0x0271 device 0x0801 class 0x00 → QCA9379 Wi-Fi (`wifi/`).

#### Bus state: SPI
- No devices on `/sys/bus/spi`.

#### Platform devices (selected; full list in evidence)
- MDSS/DSI (`1a00000.qcom,mdss_mdp`, `1a94000.qcom,mdss_dsi_ctrl0`, two DSI PLLs) → `display-panel/`
- Sound card `msm8953-snd-card-mtp` with pcm devices through ADSP → `speaker/`, `microphones/`, `echo-cancellation/`
- CAMSS stack: `msm_csiphy` ×2, `msm_csid` ×3, `vfe` ×2, `s5kc505a`, two `msm_actuator`, two `msm_eeprom` → `camera/` (two actuator/eeprom pairs suggests an aux sensor slot wired but possibly unpopulated — open question)
- Venus (`msm_vidc` in debugfs) → `video-decode/`
- `qcom,coresight-hwevent` at `6101000`

## 4. Stock behaviour

#### Input devices
- `qpnp_pon` (kpdpwr/KEY_POWER plus resin/KEY_VOLUMEDOWN — no physical power key is wired), `fts_ts`, `hbtp_vm`, `gpio-keys` with: `camera_switch` (GPIO 87), `mute` (GPIO 86), `vol_up` (GPIO 85). Measured 2026-10-30: the only switch actually fitted is the camera shutter, it delivers `KEY_POWER`, and it does not mute the mic; GPIO 86 is unwired (`../privacy-switches/`). No volume_down node — single volume key or down via another mechanism (open question). Maps to `buttons/` and `privacy-switches/`.

#### LEDs
From `/sys/class/leds`: `red`, `green`, `blue`, `lcd-backlight`, `wled`, `torch-light0`, `torch-light1`, `mmc0::`, `mmc1::`.

- `green` → `soc/leds-qpnp-22` = PMI8950 **MPP2**, max 40 (GPL: `qcom,leds@a100` / `led_mpp_2`, `linux,name = "green"`).
- `blue` → `soc/leds-qpnp-23` = PMI8950 **MPP4**, max 40 (GPL: `qcom,leds@a300` / `led_mpp_4`, `linux,name = "blue"`).
- `red` → `soc/qpnp-smbcharger-19/leds/red`, max 255 — the PMI8950 charger's own RGB/status LED, even though `qcom,charging-disabled` is set (the unit has no battery and runs from the barrel jack).
- These three status LEDs are **new relative to the README list** and are a straightforward mainline `leds-pm8941-mpp` / charger-LED job.
- `torch-light0/1` are qpnp-flash camera torch LEDs (belong to `camera/`).

#### Other V4L / misc nodes
- `/dev/radio0` = `radio-iris` (FM). FM lives in WCNSS in stock; mainline deletes `wcnss`, so FM is almost certainly a no-go on mainline unless WCNSS firmware is loaded — flagged **new**, likely out of scope.
- `/dev/video0/1` (Venus?), `/dev/video32/33` (camera ISP nodes).

#### Audio and Bluetooth nodes
- BT DT node: `bt_qca9379` compatible `qca,qca6174`, reset GPIO 0x4c (=76 decimal, TLMM 76) → `bluetooth/`.
- WCNSS node present in stock DT (FM + older BT path); mainline deletes it.

#### Enabled DT nodes (full list)

`evidence/stock-dt-enabled-nodes-20261030.txt` — 499 nodes with `status` absent/ok/okay, each with `compatible` (generated from `../stock/device-tree/` on 2026-10-30; the complete decompiled tree is `../stock/stock-device-tree.dts`, 12,433 lines).

#### Answers to the brief's questions

1. **FM radio**: `radio-iris` exists and WCNSS is enabled in stock. Whether an antenna is actually wired is unverified. FM is IRIS inside WCNSS, so mainline would need WCNSS firmware + SMD. Flagged **new**, likely out of scope.
2. **mpss/wcnss memory regions**: present in stock DT (`wcnss_fw_region` and friends); confirmed candidates for mainline deletion per the brief.
3. **Sensors**: ADSP-side, and the SSC path is broken on this build. Boot log: `slpi_loader_do: scheduling work to load SLPI fw` then `slpi_load_fw: pil get failed` / `SLPI image loading failed`, after which the sensors client attaches to the ADSP instead (`sysmon ... Connection established ... and adsp's SSCTL service`) — `../stock/stock-boot-dmesg-20261030.txt:798-803,1037`. They have **no nodes in the Lenovo GPL DTS at all** and are not on any BLSP I2C.
4. **Anything not in the README**: RGB status LEDs (see above), two torch/flash LEDs, FM radio, a `qcom,qpnp-haptic` node (present but `status = "disabled"` in GPL — no vibrator), NFC pinctrl only (no NFC device node, inherited dead config), no hall sensor, no USB hub or Type-C controller beyond the PMI8950 Type-C block.
5. **Two hardware revisions**: not in the sense of board ID — the Lenovo GPL DT is a **single** board file. The three touch controllers are alternative population options for one design; this unit is the FocalTech one. The "two revisions" in the mainline DTS therefore reflect different physical units, not different DT branches.
6. **TrustZone/BLSP**: `i2c_2`, `spi_3` and `i2c_5` are disabled in GPL; the sensor path is not on BLSP. BLSP UART (BT) works normally. Nothing we need is on a TZ-protected bus except the sensors, which are not on a bus mainline can currently reach at all.

## 5. Mainline state (7.3)

Node-by-node comparison is done in the per-device briefs; what follows is only the tree-level picture.
 From `../../kernel/linux/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts`:
- The DTS carries both the Himax and FocalTech touch nodes (both `disabled`, nothing selects one) plus the FT8201 panel node (whose `compatible` matches no driver).
- The device is aarch64-only; the Lenovo GPL reference is 32-bit, so the mainline DTS must be treated as the primary artifact and the GPL tree as the wiring oracle.
- Mainline deletes `mpss`/`wcnss`; the `ramoops`/PMIC set present here is the usual msm8953-mainline base.

## 6. Gap and plan

1. Use `evidence/gpl-dts-apq8053-lite-dragon-v2.0-201218.txt` as the canonical wiring table for every other brief and check it against the live DT. Done in the pinmux table above for the APPS side.
2. Hand the GPIO 6/7 finding to `accelerometer/` and `proximity-light/`; those briefs decide between `i2c-gpio` and enabling `blsp_i2c2`.
3. Hand the gpio-keys map (85/86/87) to `buttons/` and `privacy-switches/`.
4. Hand the LED map (MPP2 green, MPP4 blue, charger red, torch0/1) to `backlight/` (wled separation) and `camera/` (torch).
5. Compare every entry of `evidence/stock-dt-enabled-nodes-20261030.txt` with the mainline DTS and list the deltas in the owning brief. Test = DT diff review plus boot-time `dmesg` on the target.

## 7. Risks

- Charger LED `red` is bound to `qpnp-smbcharger` even though charging is disabled; touching that node can affect power-path behaviour.
- MPP2/MPP4 drive real LEDs at 40 mA-scaled current; a wrong `current-setting` can overdrive the green/blue LEDs.
- The sensor pins 6/7 are currently driven by the ADSP. If mainline claims them without stopping the SSC first, both ends will drive the bus.

## 8. Open questions

- GPIO 6/7 carrying the BMA253 and VCNL4200 is now settled by the vendor SSC config (`I2C SDA_1`/`SCL_1`); what remains is confirming it on mainline once the ADSP is out of the way.
- Is the `qcom,qpnp-haptic` vibrator populated on this board?
- Second actuator/eeprom pair on CAMSS: aux sensor slot populated or not?
- Full boot-time dmesg (ring buffer rolled; would require a reboot, currently forbidden).
- `volume_down`: not in `gpio-keys` because it is PM8953 `resin` via `qpnp_pon` `pon_2` — settled in `../buttons/ANALYSIS.md`. The residual question there is whether kpdpwr is wired to anything at all.
- Does the FM antenna exist, or is `radio-iris` dead wiring?

## 9. Sources

- Live device over adb, 2026-10-30: `/sys/bus/*`, `/proc/bus/input/devices`, `/sys/class/leds/*`, `/sys/class/video4linux/*`, `/proc/asound/*`, `/sys/kernel/debug/{gpio,pinctrl}`, dmesg grep.
- `../stock/device-tree/`, `../stock/stock-device-tree.dts` (captured 2026-10-30).
- `../stock/stock-boot-dmesg-20261030.txt` — full boot log; the two accidental reboots behind it, and their cause, are in `../stock/README-boot-capture-20261030.md`.
- Lenovo GPL opensource tarball `lenovo_cd-18781y_cd-18781y.201218.2018_opensource.tgz` (downloaded 2026-10-30): `apq8053-lite-dragon-v2.0.dts{,i}`, `apq8053-lite-dragon.dtsi`, `apq8053_IoE-perf_defconfig`, `drivers/sensors/`.
- `../README.md`, `_inventory/BRIEF.md`.
