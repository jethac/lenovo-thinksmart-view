# CPU frequency and thermal

## What this is

CPU frequency scaling across the 8 Cortex-A53 cores (up to 1.8 GHz on this unit), thermal sensors (TSENS), thermal zones and cooling, and GPU devfreq interplay.

## Done when

CPUs scale to 1.8 GHz under load and down when idle, sustained load throttles rather than crashes, and temperatures under a 10 minute full load are recorded.

## Known so far

- Stock frequencies: 652.8, 1036.8, 1401.6, 1689.6, 1804.8 MHz, governor `interactive`. The device is passively cooled.
- Stock runs Qualcomm `thermal-engine` with a config in `/vendor/etc`.

## Stock capture

- `/vendor/etc/thermal-engine*.conf`, thermal zones and trip points (`/sys/class/thermal/thermal_zone*/{type,temp,trip_point_*}`), and CPU voltage levels from the stock device tree (CPR tables, `qcom,cpr` nodes).

## Questions

- How msm8953 cpufreq works in 7.3: driver, OPP table, voltage scaling (CPR or fixed), and whether 1.8 GHz is enabled for APQ8053.
- Thermal trip points in `msm8953.dtsi` versus stock thermal-engine limits.
- Speed bin of this chip (fuses), which can change allowed frequencies.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
