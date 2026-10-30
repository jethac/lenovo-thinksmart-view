# cpufreq / thermal

Status: **ready for integration** (patches 0201-0204, tested on the device
2026-10-30). Device left on the baseline kernel.

## Summary

- cpufreq already worked on the baseline. "Failed to set OPP config" (x2) is
  a probe deferral printed as an error; cpufreq probes on the next pass.
- Scaling 652.8-1804.8 MHz, schedutil, one policy for all eight cores,
  CPR4 open-loop voltages per this chip's fuses (bin 6, rev 3). Nothing
  above 1804.8 MHz is enabled: the fuses exclude 2016/2208.
- 10 minutes of all-core load at 1804.8 MHz peaks at 61.6 C with no
  throttling, in this room. The new thermal policy (0204) only acts in a
  hot environment; its mechanism was verified with lowered test trips.
- Idle: CPUs ~99 % in power collapse, clusters ~98 % in GDHS, 79-82 % of
  time at 652.8 MHz.

## Patches (`kernel/patches-wip/cpufreq/`)

| Patch | What | Why |
| --- | --- | --- |
| 0201 | `qcom-cpufreq-nvmem`: `dev_err_probe()` for the OPP config failure | Silences the deferral (reason recorded in `devices_deferred`), real errors still print, now with the error code. Upstream master still has the plain `dev_err()`. Upstreamable. |
| 0202 | `cpr4pd`: arrays on the APC supply when the target equals the APM threshold (`>=`) | The 1804.8 MHz OPP lands exactly on the 850 mV threshold on this chip; mainline put the arrays on MX there, downstream `cpr3_regulator_switch_apm_mode()` (and its crossing test `last < apm <= new`) puts them on APC. Matches stock. cpr4pd is msm8953-mainline only, so this goes to that tree. |
| 0203 | `psci`: don't request PC mode when the DT has `force-psci-domains` | Removes `psci: [Firmware Bug]: failed to set PC mode: -1`. `force-psci-domains` is an msm8953-mainline property (not upstream), so this belongs with that series. No functional change: the call failed and changed nothing. |
| 0204 | DTS: two-stage CPU thermal policy | See "Thermal policy". |

Upstream (torvalds master, checked 2026-10-30) and every msm8953-mainline
branch up to `barni2000/7.3/develop` (our base, branch head) have none of
these. `7.1.3/main` has no differences in `cpr4pd.c`, `psci.c` or the
msm8953 thermal zones.

## Root cause of "Failed to set OPP config"

`qcom_cpufreq_probe()` calls `dev_pm_opp_set_config()` (supported_hw only,
no clock/regulator lookup). The only path in it that can fail and later
succeed is `_allocate_opp_table()` -> `dev_pm_opp_of_find_icc_paths()`,
which returns -EPROBE_DEFER until both interconnect providers of the CPU
nodes (BIMC, and the APCS CCI provider at `b011050.clock-controller`) are
registered. The driver printed that as an error and returned; it probed
on a later pass at 0.38 s (`cpufreq_policy_online` line). With 0201 the
boot log has neither line and `devices_deferred` is empty after boot.

## State (measured, baseline and patched identical)

- Driver `cpufreq-dt` via `qcom-cpufreq-nvmem`; `related_cpus 0-7` (one
  `apcs-cpu0-pll` feeds both cluster muxes and the CCI). Governor
  `schedutil` (kernel default). Transition latency 1 ms.
- OPPs: 652.8 844.8 1036.8 1228.8 1420.8 1612.8 1804.8 MHz.
- Fuses (exported nvmem cells): speed bin 6, CPR fusing revision 3. Bin 6
  selects `opp-supported-hw` bit 6; stock's clock driver for bin 6 also
  stops at 1804.8 MHz.
- Rail `pm8953_s5` per OPP (userspace governor, then restored):

| MHz | 652.8 | 844.8 | 1036.8 | 1228.8 | 1420.8 | 1612.8 | 1804.8 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mV | 650 | 665 | 680 | 715 | 745 | 775 | 850 |

  Mainline `cpr4pd` is open-loop only (fused reference voltages,
  interpolated): LowSVS 650, SVS 680, NOM 790, TURBO 955 mV at 652.8/
  1036.8/1689.6/2016 MHz, per-bin adjustment {25, 0, 5, 40} = stock's
  `qcom,cpr-open-loop-voltage-fuse-adjustment` for bin 6 rev 3. All values
  are at or below stock's per-corner ceilings and equal stock's open-loop
  values (stock at 1804.8 MHz: 850 mV). So mainline runs at or above what
  stock's closed loop settles at: safe, slightly more power. No closed loop.
- OPP ordering checked in `drivers/opp/core.c` `_set_opp()`: voltage
  (required OPP) before the clock when going up, after it when going down.
  Mismatched f/uV pairs in the sampled logs are sysfs read races.

## Measurements (`results/`, script `measure.sh`)

All with the screen on (backlight 2000), room temperature, idle CPU
sensors 29-32 C.

| | baseline | patched |
| --- | --- | --- |
| sha256 1 core (cpu0 / cpu4), MB/s | 755 / 764 | 759 / 762 |
| sha256 8 cores, 10 s, MB/s | 6076 | 6061 |
| 10 min all-core, mean MB/s (t > 10 s) | 6096 | 6098 |
| 10 min all-core, time at 1804.8 MHz | 100 % | 100 % |
| peak CPU sensor / GPU sensor | 61.6 / 47.9 C | 61.6 / 47.9 C |
| after 60 s cooldown | 33.9 C | ~35 C |
| idle 60 s: time at 652.8 / 844.8 MHz | 79 % / 17 % | 82 % / 10 % |

Temperature curve (hottest CPU sensor, all-core 1804.8 MHz): 53 C at 10 s,
57 at 1 min, 59 at 2 min, 60 at 5 min, 61 at 8 min, 61.6 at 10 min
(+0.3 C over the last two minutes, close to steady state).

Frequency follows load: idle sits at 652.8-1228.8 (1228.8 while the
sampling shell itself runs); one busy thread or eight -> 1804.8 MHz within
0.25-0.5 s; back down within 0.25 s after the load stops. The rotating
logo test's "1.23 GHz" was schedutil's choice for that light load, not a
cap.

## Thermal policy (0204)

Always-on, passively cooled, on a desk: full speed for bursts, a mild cap
before anything drastic, and no shutdown unless something is really wrong.

- **warm, 75 C** (clears at 70 C): cap at 1420.8 MHz at most (cooling
  state 2). -21 % peak throughput, about -40 % dynamic power (745 vs
  850 mV).
- **passive, 85 C** (was 80 C): full range, down to 652.8 MHz.
- **critical, 100 C** unchanged (orderly power off).
- **GPU zone**: existing 70 C GPU devfreq trip kept; new 80 C trip that
  also throttles the CPUs, since the GPU zone's critical (90 C) is the
  lowest in the system. The GPU sensor runs ~14 C below the CPUs under CPU
  load.
- Governor `step_wise` (kernel default). All eight CPU zones map to the one
  cpufreq cooling device; the highest requested state wins.

Stock for comparison: `thermal-engine.conf` is empty; at boot
thermal-engine disables msm_thermal's 60 C polling loop (`set_enabled
enabled = 0` at 6.3 s), leaving its compiled-in defaults plus msm_thermal's
emergency limits (1036.8 MHz and hotplug at 105 C, reset at 115 C).

Margin: in this room the worst CPU load peaks 13 C below the warm trip, so
the cap acts only in a hot room, in sun, with the back covered, or with
heavy GPU load on top.

### Throttle test (lowered trips, test DTB only)

The real trips never act in this room, so the mechanism was tested with
the 0204 DTB with the trips lowered by `fdtput` (warm 75 -> 50 C, passive
85 -> 56 C; nothing else changed), 10 minutes all-core
(`results/throttle-test-soak.txt`):

- warm trip engaged at ~45 s; the hottest sensor then held 50-54 C for the
  rest of the run (vs 61.6 C unthrottled); the 56 C full-range trip was
  never reached.
- cooling state stayed within 0-2 as designed: 1420.8 MHz 42 %, 1612.8
  MHz 50 %, 1804.8 MHz 8 % of the time; nothing below 1420.8.
- throughput 5.17 GB/s mean (-15 % vs 6.10 GB/s unthrottled).
- released after the load stopped (state 0, back to schedutil).
- no warnings, no resets.

So the first stage holds a sustained all-core load about 4 C over its trip
with a 15 % throughput cost, and the full-range stage stays in reserve.

**The 50/56 C trips exist only in that test DTB.** `msm8953.dtsi` has
80/100, 0204 has 75/85/100. See "Incident" below for how other streams
ended up running it.

## PSCI and cpuidle

- Firmware is PSCI 1.0, OSI-capable, and stays in OSI mode: it answers
  SET_SUSPEND_MODE(PC) with NOT_SUPPORTED. Mainline asks for PC by default
  in `psci_1_0_init()`, hence the "[Firmware Bug]" line; `cpuidle-psci-domain`
  already skips its own mode switch because of `force-psci-domains`, and
  uses the OSI hierarchy. 0203 drops the useless PC request. Nothing about
  idle changes.
- `psci_idle`: per CPU WFI and cpu-pc (power collapse); cluster genpd
  states ret / gdhs / pc. Idle 60 s: each CPU ~99 % in power collapse,
  each cluster ~98 % in GDHS. **Cluster power collapse (S2) is almost
  never chosen** (1-4 ms total in minutes). The genpd CPU governor picks
  it only when every CPU of the cluster has its next timer > 2.5 ms +
  power-off latency away; something wakes a CPU more often than that.
  GDHS already keeps the cluster mostly off, so the gain is small. Open,
  low priority: find the periodic wakeup (timer_list / tracing), not done
  here.

## Hazards found

- **Do not read `/sys/bus/nvmem/devices/qfprom0/nvmem` raw.** It reset the
  device (TrustZone-protected rows). Use the exported cells under `cells/`.
- **`kernel/deploy-to-device.sh --reboot` did not always reboot** (`adb
  reboot` answered "error: closed", `wait_back` still said "back"). I hit
  it on my first deploy, noticed it (uptime 47 min), and from then on
  rebooted with `systemctl reboot` and checked for a new boot_id. The
  integrator has since fixed the script the same way. Every result here is
  tied to its kernel by behaviour only that kernel has: baseline = two OPP
  errors and 80/100 trips; patched = neither log line and 75/85/100 trips
  (the patched soak ran on that same boot); throttle test = `uname -v`
  19:30 build and 50/56 trips, checked live before the run.
- The script defaults to `SRC=linux-7.3` for `modules_install`; for a
  stream build pass `SRC=wt-<stream>`.
- No hard resets during this work. The earlier unexplained reset is
  explained by the raw QFPROM read above; no CPR or clock experiment here
  produced a reset or a kernel warning (two 10-minute soaks at 850 mV /
  1804.8 MHz with the 0202 APM change, plus the throttle test).

## Incident 2026-10-30: other streams ran on the cpufreq test kernel

1. Under the lock, I deployed `build-cpufreq` with the 50/56 C test DTB and
   rebooted it (verified by boot_id), then ran the throttle soak.
2. Between my reboot and the soak, the wifi stream deployed `build-wifi`
   with `--reboot`. The reboot did not happen (the `adb reboot` bug below),
   so the device kept running my test kernel. /boot then held build-wifi,
   and `.prev` held my test kernel.
3. The ASR bench and the view-hal observations ("trips at 50/56 C,
   capped at 1612.8 MHz idle") ran on that test kernel, so their CPU
   numbers are throttled and should be rerun on the baseline.
4. A queued `deploy-to-device.sh --rollback --reboot` from another session
   would have restored `.prev`, which is the test kernel, not the baseline.
   I queued a locked job that deploys `build-7.3`, reboots, and checks
   the md5s and trips instead (see final state below).

## For the integrator

1. Move `0201`-`0204` into `kernel/patches/` (they apply in order on top of
   0001-0003 and build clean, also with the new ZRAM/PSI config fragment).
2. No config change needed.
3. Rebuild the baseline and check on the device: no "Failed to set OPP
   config", no "failed to set PC mode", `cat
   /sys/class/thermal/thermal_zone4/trip_point_*_temp` shows 85000 100000
   75000, and `gpu-thermal` has an extra 80000 trip.
4. Rerun any CPU-bound numbers taken between about 03:49 and 04:22 device
   time (ASR bench, view-hal): they ran on the cpufreq test kernel.
5. Upstreaming: 0201 to linux-pm; 0202 and 0203 to msm8953-mainline.

- The Image.gz in the second `build-cpufreq` build is about 10 KB larger
  because `config/lenovo-cd-18781y.config` gained PSI and zram in the
  meantime (`.config` differs from build-7.3 only there). The before and
  after numbers come from the first build, without those options; the
  throttle test used the second.

## Left on the device

Nothing. At release the device runs the baseline (`uname -v` 10:12 build;
Image and DTB md5 equal to `kernel/build-7.3`; trips 80/100; no `.prev`
files). The restore itself was done from the coordinator's side; I
withdrew my queued restore so the device would not reboot again needlessly.
`/tmp/measure.sh` is gone (tmpfs). `results/` holds the logs;
`measure.sh` is the script (pushed to /tmp on the device to run).
