# eMMC and partition layout

## What this is

The 8 GB eMMC on `sdhc_1` (`7824900.sdhci`), 15269888 sectors (7.28 GiB), and the GPT on it.

## Done when

There is a final partition layout for the Arch Linux ARM system with every firmware and calibration partition preserved, a tested way to write it, and a tested way back to the stock layout. eMMC health is recorded.

## Known so far

- Stock layout: `../../backup-20261029/stock_layout.sfdisk`, both GPT copies alongside.
- The rickx Ubuntu layout (`../../ubuntu-thinksmart/partitions/ubuntu_layout.sfdisk`) keeps p1 to p24, grows `system` (p24) to about 6.8 GiB, and moves `persist` (p27) to the end of the disk. It drops p25, p26 and p28 to p51, including `vendor`, `cache`, `misc`, `keystore`, `config`, `oem`, `cmnlib*`, `keymaster*`, `lksecapp*`, `mdtp`, `dpo`, `logdump`, `resource`, `userdata`.
- `persist` content is not carried over by the rickx GPT script. It must be restored from backup.
- The stock toybox `dd` rejects `bs=1M` and cannot seek past 2 GiB. Use the Termux `dd` on stock.

## Stock capture

- eMMC identity and health: `/sys/block/mmcblk0/device/{name,manfid,oemid,date,fwrev}` and, if available, `life_time` and `pre_eol_info`, or `ext_csd` from debugfs.

## Questions

- Which dropped partitions does `aboot` or TrustZone read at boot? (For example `keymaster`, `cmnlib`, `lksecapp`, `devcfg`, `dip`, `mdtp`.) The rickx layout boots, but check whether anything degrades.
- Is it better to keep the stock GPT and use `userdata` (about 2 GiB) plus `system` (1.5 GiB) separately, or to merge as rickx does? Size it against the Omarchy package list.
- Where should `/boot` (lk2nd reads `extlinux.conf`) live, and which filesystem types does lk2nd read?

## Hazards

- Never overwrite `persist`, `modemst1`, `modemst2`, `fsg`, `devinfo`, `sbl1`, `rpm`, `tz`, `aboot`, `devcfg` or their backups.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
