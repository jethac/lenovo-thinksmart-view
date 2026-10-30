# Screen off and power management — ThinkSmart View CD-18781Y

## 1. Summary

Stock never puts the SoC to suspend: `suspend_stats` shows 0 successes after 2 h uptime, and every wake source in `debugfs/wakeup_sources` is an Android wakelock (`PowerManagerService.Broadcasts`, `hal_bluetooth_lock`, `wlan_*`), not hardware. Screen off on stock is a backlight blank plus aggressive low-power-mode idling, with touch, the volume keys and proximity as the hardware wake paths. Mainline inherits that shape: the goal is blank/unblank that survives, with hardware wake sources, and an honest statement about suspend. The known-unrecoverable DPMS off is the central technical problem and it has a plausible mechanism in the TDDI shared reset plus LAB/IBB.

## 2. Identity

- Panel/backlight/touch as per `../display-panel/`, `../backlight/`, `../touch/` — the three are one TDDI subsystem here.
- Stock `debugfs/wakeup_sources`: 2042 events on `hal_bluetooth_lock`, and the whole table populated from Android daemons (`PowerManagerService.Broadcasts`, `lowi-server`, `qcom_rx_wakelock`).
- Stock `/sys/power/state` = `freeze mem`; `suspend_stats` all zero.
- Mainline `/sys/power/` has the standard files; `msm8953.dtsi` has one `wakeup-source` (line 2305) and no PDC/RSC always-on block.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Screen off method | backlight/LED blank + LPM idle | DRM DPMS / connector off + DPMS-aware backlight | different model |
| Suspend | not used | `mem`/`freeze` available, unproven | gap |
| Wake sources | touch, keys, proximity (all `wakeup-source` in DT), plus wakelocks | volume-up and resin have `wakeup-source`; touch and proximity do not | partial |
| Wakeup sources list | Android wakelocks | none configured | gap |
| TDDI reset | GPIO 64 shared panel+touch | same, not coordinated | risk |

## 4. Stock behaviour

- Screen off: the panel is blanked and the WLED goes to 0; the SoC keeps running and enters deeper LPM states opportunistically. That is why `suspend_stats` is empty — Android's model here never relies on `mem`.
- Wake: touch interrupts, key presses, proximity — the drivers hold wakeup capability (`H: Handlers=mdss_fb kgsl event1`, and the proximity sensor is a `wakeUp` sensor).
- Because nothing suspends, wakelock hygiene is the power story, and `hal_bluetooth_lock` at 2042 events shows how busy that is even at idle.

## 5. Mainline state

- No suspend configuration; `pm_test` and `freeze` exist but nothing has exercised them.
- `wakeup-source` is set for the volume keys; touch and proximity are not wakeup-capable in the DT yet.
- The DPMS-off failure is recorded from the prior port: connector off, unrecoverable without a compositor restart. Mechanism candidates, in the order they should be eliminated: the panel `unprepare` asserting the TDDI reset; LAB/IBB being dropped under a still-live DSI PHY; the touch driver holding the shared reset while the panel comes back; MDSS not relocking the DSI PLL.

## 6. Gap and plan

1. Fix display off/on properly (steps 3-4 in `../display-panel/`), because everything here depends on it.
2. Establish wake sources: add `wakeup-source` to the touch node and to the proximity sensor, then test each from a blanked screen.
3. Test blank/unblank 50 times in a row from each trigger (idle timer, key, proximity) and count failures rather than judging by eye.
4. Only after that, try suspend: `echo mem > /sys/power/state` with `pm_test=devices` first, then `platform`, then full. Record where it fails, if it does.
5. Measure power with an inline meter on the barrel jack at: idle screen on, screen dim (10/255), screen off, and suspend if it works. Those four numbers are the deliverable.
6. If suspend works, decide policy: sleep on blank is worth it for heat, but proximity wake then has to work from suspend and the WLED/panel cold-start must be quick.

## 7. Risks

- Suspend with a half-initialised TDDI leaves the panel and touch dead on resume, which is worse than not suspending.
- A missing wakeup source means the device is unreachable once suspended — with no battery and no reset button, only the barrel jack.
- LAB/IBB sequencing errors during off can invert or over-drive the panel on the next on.
- `interactive`-style aggressive idle flashing on and off can wear the backlight connector; test with sustained cycles.

## 8. Open questions

- Does s2idle or deep suspend even reach the firmware on msm8953 mainline, or does it stop at "freeze"?
- Why does DPMS off not recover — reset, LAB/IBB, or MDSS PLL? Needs instrumentation, not more speculation.
- What wakes the device from suspend if proximity is disabled by the privacy state?
- Is idle power low enough without suspend to make suspend optional?

## 9. Sources

- `evidence/stock-suspend-wakeups-20261030.txt`, `evidence/stock-pm-state-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/msm8953.dtsi:2305`; `apq8053-lenovo-cd-18781y.dts` (pinctrl sleep states).
- `../../ubuntu-thinksmart/README.md` (DPMS-off workaround); `power-management/BRIEF.md`; related analyses above.
