# Display panel

## What this is

The 8 inch 800x1280 DSI video-mode panel on `&mdss_dsi0`, 4 lanes. Stock identifies it as `mdss_dsi_boyift8201_800p_video` (kernel command line `mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_boyift8201_800p_video`). Mainline uses `compatible = "lenovo,cd-18781y-panel"`, reset GPIO 61, backlight enable GPIO 95, supplies `panel_avdd`, LAB and IBB.

## Done when

Native 800x1280 under Hyprland, correct orientation, no tearing or flicker, survives screen off and on.

## Known so far

- The panel name says FT8201: a FocalTech touch and display driver IC (TDDI). The touch controller and panel controller are the same chip on this unit, which matters for touch and power management.
- The mainline DTS describes two touch controllers (FocalTech FT8201 at `0x38`, Himax HX83100A at `0x48`). That suggests two panel variants. lk2nd selects the panel from what `aboot` reports.
- rickx: on Plasma 6, turning the DRM connector off is unrecoverable without restarting the compositor.

## Stock capture

- The full stock panel node from `/proc/device-tree` (look for `qcom,mdss_dsi_boyift8201_800p_video`): init and off command sequences (`qcom,mdss-dsi-on-command`, `-off-command`), timings, lane config, reset sequence and power-on delays.
- Any other panel nodes in the stock DT (other variants).

## Questions

- 7.3 has three generated panel drivers in `drivers/gpu/drm/panel/msm8953-generated/`: `panel-lenovo-cd-18781y-ft8201.c`, `-hx83100a.c` and `-jd9365.c`. The JD9365 one is not in that directory's Makefile or Kconfig, so it cannot be built. Find out which variant uses JD9365, and whether its driver is finished.
- Do the FT8201 driver's init commands match the stock `boyift8201` sequence byte for byte? The drivers are generated from downstream DTs (`linux-mdss-dsi-panel-driver-generator`), so compare against this unit's stock DT, not another unit's.
- How does lk2nd pick the panel, and what does it pass to the kernel for this unit?
- Native orientation, and the right `rotation` property for the default use (portrait or landscape).
- Why does DPMS off not come back (panel driver `unprepare`/`prepare`, TDDI reset, or MDSS)?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
