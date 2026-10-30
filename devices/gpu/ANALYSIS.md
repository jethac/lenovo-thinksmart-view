# GPU — ThinkSmart View CD-18781Y

## 1. Summary

Adreno 506 (`qcom,adreno-506.0`), driven by `msm` DRM + freedreno, needs the signed per-device zap shader (`a506_zap.mdt`) and `a530_pfp.fw`/`a530_pm4.fw`. The mainline OPP table is an exact match for stock's power levels (19.2 MHz to 650 MHz), so frequency scaling is covered. Mesa's freedreno still carries a5xx paths, so hardware GL/GLES is realistic; **Turnip has no a5xx support**, so Vulkan is very likely unavailable and `GOAL.md`'s "GL and Vulkan" line needs amending rather than chasing.

## 2. Identity

- `gpu@1c00000`, `compatible = "qcom,adreno-506.0", "qcom,adreno"` (`msm8953.dtsi:1926-1927`).
- Firmware: `a506_zap.mdt` from the vendor partition, device-specific `firmware-name = "qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt"`; `a530_pfp.fw` / `a530_pm4.fw` in `/vendor/firmware`.
- Stock capabilities (blob): OpenGL ES 3.2 AEP, Vulkan 1.0.3. Stock pwrlevels: 650, 560, 510, 400, 320, 216, 133.3, 19.2 MHz.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| OPP list | 19.2-650 MHz, 8 levels | identical `gpu_opp_table` (`19.2/133.3/216/320/400/510/560/650 MHz`) | yes, exact |
| Power domain | GX GDSC | `power-domains = <&gcc OXILI_GX_GDSC>` | yes |
| IOMMU | GPU SMMU | `iommus = <&gpu_iommu 0>` | yes |
| Zap shader | `a506_zap.mdt` in `/vendor/firmware` | same name under a device path | path only |
| GPU firmware | `a530_pfp/pm4.fw` | linux-firmware `qcom/a530_*` | yes |
| Devfreq | vendor `kgsl` | `operating-points-v2` + devfreq | equivalent |

## 4. Stock behaviour

- Qualcomm `kgsl` out of tree, with the blob GL/VK driver stack. Frequency scaling driven by `qcom,gpu-pwrlevels` and bus votes (`qcom,bus-freq*`), so the GPU is tied to DDR/CPU bus levels rather than a standalone governor.
- Zap shader is loaded through the secure PIL path, i.e. it is signed and board-specific — a generic one will not do.

## 5. Mainline state

- `msm` DRM with freedreno; opp table, GDSC and IOMMU all present; the zap shader path is already device-specific.
- Devfreq on OPPs replaces the vendor pwrlevels.
- Mesa side: the local Arch build (26.2.5) contains a5xx code paths and the `a530` name, so GL/GLES should attach. `vulkan-freedreno` (Turnip) is a separate package and upstream Turnip supports a6xx and newer only — a5xx is not implemented.

## 6. Gap and plan

1. Amend `GOAL.md`: Vulkan is out of scope unless someone writes a5xx Turnip support; the honest statement is "hardware GL/GLES under Hyprland, no Vulkan".
2. Install the zap shader and `a530_pfp/pm4.fw`; confirm the secure PIL load in `dmesg` before any GL work.
3. Bring up `msm` DRM and run `glmark2-es2-drm` and `es2_info` on the framebuffer first, then under Hyprland with `aquamarine`.
4. Verify devfreq actually scales: `cat /sys/class/devfreq/*/cur_freq` while running glmark2, and check for thermal throttling alongside `../cpufreq-thermal/`.
5. Watch for a5xx Mesa regressions: run glmark2 for 30 min and keep the log; if the renderer hangs, try `MESA_GL_VERSION_OVERRIDE`/`FD_MESA_DEBUG=noinorder` before blaming the kernel.

## 7. Risks

- Wrong or missing zap shader leaves the GPU in a state where the driver refuses to init (not a brick).
- A 650 MHz sustained load on a fanless tablet-size board will thermally throttle; a poor devfreq governor can oscillate.
- Mesa a5xx sees little testing; expect renderer bugs rather than kernel bugs.
- The GPU shares the DDR bus with the panel; GPU load can cause display underruns.

## 8. Open questions

- Does current Mesa freedreno actually initialise a506, or only a530-class parts? Needs a device test.
- Is any a5xx Turnip work in progress upstream?
- What is the sustainable GPU clock before thermal throttling on this chassis?
- Does Hyprland's renderer accept GLES 3.x-only hardware without falling back to software?

## 9. Sources

- `evidence/stock-gpu-pwrlevels-20261030.txt` (8 levels) and `evidence/mainline-gpu-opp-table-20261030.txt` (8 OPPs) — same frequencies in the same order.
- Mainline `arch/arm64/boot/dts/qcom/msm8953.dtsi:1926-2000`; `apq8053-lenovo-cd-18781y.dts:176-180`.
- Local Mesa 26.2.5 build (`/usr/lib/libgallium-26.2.5-arch1.1.so`, `a530`/a5xx strings); `pacman -Ss vulkan-freedreno`.
- `../../ubuntu-thinksmart/README.md` (Plasma/GL status); `gpu/BRIEF.md`.
