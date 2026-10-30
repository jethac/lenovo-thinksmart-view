# Wi-Fi

## What this is

Qualcomm QCA9379 hw1.0 on SDIO (`&sdhc_2`, `wifi@1`, `compatible = "qcom,ath10k"`), driven by `ath10k_sdio`. Not WCNSS.

## Done when

Joins `yareyare-xd-mesh` (5 GHz mesh) at boot, reconnects after a router restart and after GTK rekeys, and holds for 24 hours. The MAC address is this unit's own (`94:08:53:2d:0b:e5`), not random.

## Known so far

- rickx: firmware `WLAN.NPL.1.6-00163-QCANPLSWPZ-1`. GTK rekey failures (`-110`) come from the HTT security indication timing out; fixed by patching `ath10k_set_key` to swallow `-ETIMEDOUT`. See `../../ubuntu-thinksmart/research/wifi/analysis/ath10k-gtk-rekey-fix-2026-06-05.md`. That is a workaround, not a root cause fix.
- Firmware features: `wowlan,ignore-otp,mfp`, no raw mode, so `cryptmode=1` is not an option.
- The mesh uses several BSSIDs, and roaming between them is part of "reconnects".

## Stock capture

- Stock driver and firmware: `lsmod` (likely `wlan` qcacld), `/vendor/firmware/wlan`, `/persist/wlan*`, `/vendor/etc/wifi/*.ini` (`WCNSS_qcom_cfg.ini` and similar). Hash and copy board data and config files.
- Where the stock MAC comes from (`/persist/wlan_mac.bin`, NV, or OTP).
- Regulatory: country code used on stock (the user is in Japan).

## Questions

- Is the rekey problem still present on 7.3, and is there an upstream ath10k fix or a newer QCA9379 SDIO firmware?
- Is there a board data file specific to this design, and does mainline load the right one (`board-2.bin` with the right `bus=sdio,...` ID)?
- Power save: does disabling it change stability, and what does it cost in watts?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
