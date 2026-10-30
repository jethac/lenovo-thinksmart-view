# Display panel — ThinkSmart View CD-18781Y

## 1. Summary

8" 800x1280 DSI video-mode panel, 4 lanes, 60 fps, driven by a FocalTech FT8201 TDDI (touch and display in one die) — the stock panel name is literally `boyift8201_800p_video`. Under Hyprland nothing will come up today: the three generated Lenovo panel drivers are **not built at all** (absent from `drivers/gpu/drm/panel/Makefile` and `Kconfig`), the DTS asks for `lenovo,cd-18781y-panel` which matches **none** of them (they use `…-ft8201`, `…-hx83100a`, `…-jd9365`, each with a `// FIXME`), and even if it bound, the driver never requests `avdd`, so the GPIO 100 panel rail would stay off. The stock init sequence itself is tiny and is reproduced correctly by the FT8201 driver.

## 2. Identity

- Stock: `qcom,mdss_dsi_boyift8201_800p_video`, `qcom,mdss-dsi-panel-name = "boyift8201 800p video mode dsi panel"`, selected on the kernel command line (`mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_boyift8201_800p_video:1:none:cfg:single_dsi`) (`../stock/stock-device-tree.dts:7543-7580`).
- Geometry: `panel-width = <0x320>` (800), `panel-height = <0x500>` (1280), `framerate = <0x3c>` (60), `bpp = 0x18`, video mode, `burst_mode`, 4 lanes.
- Mainline: `compatible = "lenovo,cd-18781y-panel"`, `reg = <0>`, `panel_in` endpoint with `data-lanes = <0 1 2 3>`.
- Because it is a TDDI, the same die also answers on I2C `0x38` as the FocalTech touch controller (see `touch/`). Reset is shared.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Reset | GPIO 61, `reset-sequence = <1 10 0 5 1 50>` | `reset-gpios = <&tlmm 61 GPIO_ACTIVE_LOW>` | yes |
| Backlight enable | GPIO 95, `qcom,platform-bklight-en-gpio` | `backlight-gpios = <&tlmm 95 GPIO_ACTIVE_HIGH>` | yes |
| Panel VDD | GPIO 100 `qcom,ext_vdd-gpio` | `avdd-supply = <&panel_avdd>` (GPIO 100, active high) | yes, **not requested by the driver** |
| VSP / VSN | LAB / IBB | `vsp-supply = <&lab>`, `vsn-supply = <&ibb>` | yes |
| VDDIO | `pm8953_l6` | `&mdss_dsi0` `vddio-supply = <&pm8953_l6>` | yes |
| TE | GPIO 24 `mdp_vsync`, `mdss_te_active` | `mdss_te_default` on GPIO 24 | yes |
| Lane config | `00 00 ff 0f` ×4 + `00 00 ff 8f` | `data-lanes = <0 1 2 3>` | equivalent |
| on-command | `11` (delay 150), `ff 00`, `35 00`, `29` | `0x11`, `0xff 0x00`, `0x35 0x00` | matches |
| off-command | `28` (delay 150), `10` | `set_display_off`, msleep 150, `enter_sleep_mode` | matches |

## 4. Stock behaviour

- Init is minimal by design: the TDDI does its own bring-up, the host only issues sleep-out, `ff 00` (page select), `35 00` (write backlight control on), then display-on. There is no long vendor init table to port.
- Reset sequence is `1,10ms → 0,5ms → 1,50ms` (assert, hold, release, settle).
- Backlight is PMI8950 WLED (`bl_ctrl_wled`, max 0xfff) plus the GPIO 95 enable.
- `post-init-delay = <0x01>` and `lp11-init` are set; traffic is burst video mode with BLLP modes on.

## 5. Mainline state (7.3 — two concrete blockers)

On 7.1.3 the panel drivers were not wired into the build at all; on the current base (`barni2000/7.3/develop`) that is fixed — the generated directory has its own `Makefile`/`Kconfig` and `CONFIG_DRM_PANEL_LENOVO_CD_18781Y_FT8201` / `_HX83100A` are default-on. JD9365 is still absent from the Makefile, matching the brief's note. Two blockers remain:

1. **No bind.** DTS `lenovo,cd-18781y-panel` versus driver `lenovo,cd-18781y-ft8201` (the driver file itself carries `// FIXME` on that match line).
2. **Missing rail.** The driver's regulator list is only `{vsn, vsp}`; `avdd` is never bulk-enabled, so GPIO 100 stays low and the panel is unpowered. `panel_avdd` is a normal `regulator-fixed` with no `regulator-always-on`/`boot-on`.

Beyond those, the FT8201 driver's on/off sequence matches this unit's stock DT, and the JD9365 driver has no known user (nothing in the DTS references it) — it is dead code until a unit shows up.

## 6. Gap and plan

1. Fix the `compatible` mismatch: DTS `lenovo,cd-18781y-ft8201` (this unit's variant), and drop the FIXME in the driver.
2. Add `avdd` to the driver's supply list so GPIO 100 and the rail are sequenced with the rest.
3. Fix DPMS-off. `unprepare` asserts reset and drops all rails; on a TDDI that also resets the touch controller, and the touch driver must re-init after it. Test: `Hyprland` blank/unblank and `echo off > /sys/class/drm/card0-DSI-1/dpms` in a loop; expect the panel and touch to both come back. If the DSI link itself fails, keep LAB/IBB (VSP/VSN) on across a short blank and only cut them on long blanks.
4. Orientation: confirm whether the native scan is portrait. GOAL wants native 800x1280 with correct rotation for a landscape-use device — set `rotation = <90>` (or the inverse) in the panel node rather than compensating in the compositor.
5. Test tearing/flicker at 60 fps with a full-screen pattern, then a 24 h blank/unblank soak.

## 7. Risks

- Wrong lane/PHY config can produce a lit but garbled panel; wrong VSP/VSN sequencing can invert or over-voltage the panel.
- The TDDI shares reset with touch — an unprepared reset in the panel driver silently kills touch until its next open.
- GPIO 100 drives the panel rail directly; if the driver enables it out of order, panel and PHY come up in the wrong sequence.
- DPMS off is currently unrecoverable on the prior port; if that persists past boot testing, blanking becomes a compositor restart.

## 8. Open questions

- Which of the three drivers does the second hardware variant need, and is JD9365 a real third variant or dead code?
- How does lk2nd choose the panel, and does it pass a panel name to the kernel at all?
- Is the native orientation portrait, and what `rotation` makes the device read correctly in its stand?
- Why exactly does DPMS off not recover — DSI PLL re-lock, TDDI reset, or the touch driver wedging the bus?

## 9. Sources

- `evidence/stock-panel-node-boyift8201-20261030.txt`, `evidence/mainline-panel-node-73-20261030.txt`, `evidence/mainline-driver-supplies-20261030.txt` (compatible mismatch and the `vsn`/`vsp`-only supply list); `../stock/stock-device-tree.dts:34` (cmdline).
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:197-232`; `drivers/gpu/drm/panel/msm8953-generated/panel-lenovo-cd-18781y-{ft8201,hx83100a,jd9365}.c`; `drivers/gpu/drm/panel/{Makefile,Kconfig}`.
- `display-panel/BRIEF.md`.
