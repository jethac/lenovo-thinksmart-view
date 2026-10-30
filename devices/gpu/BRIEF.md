# GPU

## What this is

Adreno 506 at up to 650 MHz, `msm` DRM driver with freedreno in Mesa. Needs the signed zap shader from the device (`&gpu_zap_shader`) and `a530_pfp.fw` / `a530_pm4.fw` from linux-firmware.

## Done when

The full-screen app renders with hardware GL/GLES, the GPU scales frequency under load, and glmark2 or similar completes without hangs.

## Known so far

- Stock reports OpenGL ES 3.2 (AEP) and Vulkan 1.0.3 through Qualcomm's blob.
- Mesa's Vulkan driver for Adreno (Turnip) supports a6xx and later, not a5xx. **Vulkan on this GPU under mainline is likely not available.** Confirm, and if so amend `GOAL.md`.

## Stock capture

- Zap shader files (`a506_zap.mdt`, `.b00` to `.b03` or similar) from the stock firmware locations, with hashes.
- Stock GPU frequency table and power levels from the device tree (`qcom,gpu-pwrlevels`).

## Questions

- Does 7.3 have GPU devfreq and the OPP table for msm8953? Max frequency under mainline?
- Which GLES and desktop GL versions freedreno exposes on a506 in current Mesa, and what the full-screen app can rely on.
- Known a5xx regressions in recent Mesa.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
