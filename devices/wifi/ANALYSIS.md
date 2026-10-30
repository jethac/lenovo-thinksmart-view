# Wi-Fi — ThinkSmart View CD-18781Y

## 1. Summary

QCA9379 on SDIO (`sdhc_2`), vendor firmware `WLAN.NPL.1.6-00163-QCANPLSWPZ-1`, MAC `94:08:53:2d:0b:e5` from OTP. The one real defect is the GTK rekey timeout: `ath10k_install_key()` waits 3 s for an `HTT_T2H_MSG_TYPE_SEC_IND` that this SDIO firmware often does not send for group keys, returns `-ETIMEDOUT`, and mac80211 deauthenticates. Checked today: the code is **identical** on `7.1.3/main` and the current base `barni2000/7.3/develop`, so the byte patch the previous port used is still needed and should be replaced with a source fix. Everything else is configuration: the right board file, a pinned MAC, and regulatory for Japan.

## 2. Identity

- SDIO function `mmc1:0001:1`, `sdio:c00v0271d0801`, vendor `0x0271`, device `0x0801`.
- Driver on stock: Qualcomm `qcacld-3.0` (`/sys/module/wlan`, built in, not a loadable module — `/vendor/lib/modules` carries only unrelated test modules).
- Mainline driver: `ath10k_sdio` via `compatible = "qcom,ath10k"`.
- Firmware version string and feature set from the prior port: `WLAN.NPL.1.6-00163-QCANPLSWPZ-1`, features `wowlan,ignore-otp,mfp`, no raw mode (so `cryptmode=1` is unavailable).
- MAC: `94:08:53:2d:0b:e5` (`/sys/class/net/wlan0/address`), Qualcomm OUI, matching the DTS `local-mac-address` if one is added.

## 3. Wiring

| Item | Stock | Mainline | Agree? |
| --- | --- | --- | --- |
| Bus | `sdhc_2` SDIO, 4-bit | `&sdhc_2` with `wifi@1` | yes |
| Power / enable | `wlan_3v3` fixed regulator on GPIO 77 | same node | yes |
| Reset | `mmc-pwrseq-simple` on GPIO 75, 100 ms post-delay | same | yes |
| SD detect | GPIO 77 used as `status_irq` in stock interrupt-map | n/a (non-removable) | n/a |
| Bus speed / modes | SDR104, up to 177.77 MHz | inherited from `sdc2` pinctrl | yes |
| Firmware | qcacld + `/firmware/image/{athwlan,bdwlan30,qwlan30}.bin` | `ath10k_sdio` + same blobs renamed | name mapping |
| MAC | from OTP | not pinned in DT | gap |

## 4. Stock behaviour

- Vendor stack (`qcacld`) with `/vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini` (14 kB). Notable settings: `gEnableImps=1`, `gEnableBmps=1`, `gEnableSuspend=3` (power save heavily on), `gEnableIdleScan=0`.
- The ini's `Intf0MacAddress=000AF58989FF` is only a placeholder; the live MAC is the Qualcomm OUI above, so it comes from the chip's OTP/NV, not the ini.
- Board data lives in the `modem` partition (`bdwlan30.bin`, 8124 bytes) and is loaded by the vendor driver. There is no `board-2.bin` anywhere on the device.
- Regulatory is vendor-managed through the same ini (`SAP Country code` section present); the unit is in Japan.

## 5. Mainline state

- `wifi@1` node exists with correct regulator and pwrseq wiring.
- `ath10k_sdio` is the driver; the blobs must be installed as `ath10k/` files. `bdwlan30.bin` is the design-specific board data — it is present on this unit and is the thing that makes the radio legal and calibrated.
- **Rekey defect is unfixed upstream**: `ath10k_install_key()` still does `wait_for_completion_timeout(&ar->install_key_done, 3 * HZ)` and returns `-ETIMEDOUT`; `ath10k_set_key()` propagates it, mac80211 deauths. The completion is only ever signalled from `HTT_T2H_MSG_TYPE_SEC_IND` (`htt_rx.c:4172-4183`). Diffed `7.1.3/main` against `barni2000/7.3/develop` today: no change in `mac.c` or `htt_rx.c` on this path.
- No `local-mac-address` in the DTS, so the MAC depends entirely on what the firmware/OTP hands over.

## 6. Gap and plan

1. **Source fix instead of a byte patch.** In `ath10k_install_key()`, treat the timeout as non-fatal for `SET_KEY` (log at debug and return 0), keeping `-ETIMEDOUT` for `DISABLE_KEY` where a stuck key really matters. Alternatively wait only when the firmware is known to send `SEC_IND`. Test: `wpa_cli` forced rekey (`wpa_cli reassociate` plus a short `wpa_group_rekey`) in a loop for 30 min with `dmesg -w`; expect the warning to remain but no `deauthenticating`.
2. Install `bdwlan30.bin`, `athwlan.bin`, `qwlan30.bin` into `ath10k/`, and confirm the board-data match in the probe log (`ath10k_sdio` prints which board file it used).
3. Pin the MAC with `local-mac-address` so the identity survives firmware changes, and check that the OTP value is stable across boots before relying on it.
4. Regulatory: set `cfg80211` country `JP` at boot (or via `iw reg set JP` from a service) and confirm the 5 GHz mesh channels the user actually uses are permitted.
5. Power save: test `iw dev wlan0 set power_save off` against the mesh; measure idle power with a meter on the barrel jack before and after. Only keep it off if it materially helps stability.
6. 24 h soak with a rekey interval well under the test window, plus a router restart and a roam between mesh BSSIDs.

## 7. Risks

- The rekey fix hides an error; if the firmware genuinely fails to program a key, traffic silently uses the old one until the next rekey. Keep the warning visible.
- `bdwlan30.bin` is regulatory-critical: wrong or missing board data gives a radio that transmits out of spec.
- Forcing `power_save off` raises idle power and heat on a fanless unit.
- SDIO is on the same `sdhc_2` block as nothing else, but pulling the card's power (GPIO 77) at the wrong moment wedges the bus until reboot.

## 8. Open questions

- Does the firmware ever send `SEC_IND` for GTK, or only for pairwise? A `ATH10K_DBG_HTT` trace during a forced rekey would show it.
- Is there a newer QCA9379 SDIO firmware that fixes it, and is it signed for this board (`ignore-otp` suggests the OTP check is relaxed)?
- Is the mesh actually 5 GHz-only, or does it also run 2.4 GHz?
- Is `local-mac-address` honoured by `ath10k_sdio`, or does the firmware overwrite it?

## 9. Sources

- Live 2026-10-30: `/sys/module/wlan`, `/vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`, `/sys/class/net/wlan0/address`, `lsmod`; `evidence/stock-wifi-*.txt`.
- `../stock/inventory-sysfs-20261030.txt` (SDIO ids), `../stock/stock-pinmux-20261030.txt` (pins 75/77).
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` (wlan regulators/pwrseq); `drivers/net/wireless/ath/ath10k/mac.c:307-330,6658-6665`; `htt_rx.c:4172-4183`. Diffed against `origin/barni2000/7.3/develop` (`755ffc44d5d8`) fetched 2026-10-30.
- `../../ubuntu-thinksmart/research/wifi/analysis/ath10k-gtk-rekey-fix-2026-06-05.md` and `sources/scripts/patch-ath10k-etimedout.py`.
- `wifi/BRIEF.md`.
