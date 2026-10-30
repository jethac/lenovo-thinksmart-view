# eMMC and partition layout — ThinkSmart View CD-18781Y

## 1. Summary

SanDisk iNAND 8GTF4R, 7.28 GiB, manufactured 05/2020, still effectively unused (`life_time 0x01 0x01`, `pre_eol_info 0x01`). The stock GPT is Lenovo's 51-partition Android layout; the root-relevant part of it (`system` 1.4 GiB plus `userdata` 3.8 GiB) is nowhere near enough for Arch + Omarchy, so repartitioning is mandatory. The proven approach is rickx's: keep p1-p23 (bootloaders, modem, dsp, devinfo, splash), merge everything from `system` to the disk end into one rootfs, and move `persist` to the tail. My one disagreement is that rickx also drops `syscfg`, `mcfg`, `apdp` and `msadp`, which are cheap to keep and are the sort of thing a bootloader or TrustZone app can read before Linux exists.

## 2. Identity

- `/sys/block/mmcblk0/device/name` = `8GTF4R`, `manfid 0x000015` (SanDisk), `oemid 0x0100`, `serial 0xf7d7479a`, `date 05/2020`, `fwrev 0x0` (`evidence/stock-emmc-identity-20261030.txt`).
- Health: `life_time 0x01 0x01` (SLC and MLC both 0-10 % of rated life used), `pre_eol_info 0x01` (normal). No wear concern.
- Capacity: `15269888` sectors of 512 B = 7.28 GiB (`/sys/block/mmcblk0/size`), matching the brief's figure and the `last-lba 15269854` in both GPT dumps.
- Controller: `sdhc_1` / `7824900.sdhci`, HS400, non-removable.
- Stock identity strings: `ro.vendor.build.fingerprint` Lenovo 8.1.0, `androidboot.serialno=HUA0BMNX`.

## 3. Wiring (stock partition layout)

Full text in `../../backup-20261029/stock_layout.sfdisk`; live confirmation in `evidence/stock-live-layout-20261030.txt`. Grouped by what matters:

| Group | Partitions (start sectors) | Keep? |
| --- | --- | --- |
| Bootloaders | `sbl1` 393240, `sbl1bak`, `rpm`, `rpmbak`, `tz` 397336, `tzbak`, `devcfg` 405528, `devcfgbak`, `aboot` 786432, `abootbak`, `devinfo` 921600 | **never touch** |
| Modem/DSP firmware | `modem` 131072, `dsp` 406552, `modemst1` 439320, `modemst2` 442392, `fsg` 524352, `fsc` 393216, `ssd` 393224, `sec` 527424, `DDR` 524288 | **never touch** (calibration) |
| Boot | `boot` 790528 (32 MiB), `recovery` 856064 (32 MiB), `splash` 655360 | `boot` yes; `splash` yes |
| Calibration / config | `persist` 5238784, `mcfg` 5836800, `syscfg` 5835776, `apdp` 6029312, `msadp` 6029824, `limits` 5636096 | `persist` **must**; others cheap |
| Android system | `system` 923648 (1.5 GiB), `vendor` 4069376 (384 MiB), `cache` 4980736, `oem` 5307456, `misc` 5304320, `keystore` 5306368, `config` 5307392, `mota`, `dip`, `mdtp`, `logdump`, `resource`, `userdata` 6890512 (4 GiB) | merged into rootfs |
| TZ apps | `lksecapp` 5898240, `cmnlib` 5898752, `cmnlib64` 5902848, `keymaster` 5906944 (+ all `*bak`), `dpo` | merged (Android keystore only) |

Live usage: `/data` 3.3 G of 3.8 G, `/system` 935 M of 1.4 G, `/vendor` 129 M, `/cache` 444 K.

Factory reference: Lenovo's own `rawprogram_unsparse.xml` (Zoom 210602.2103) rewrites all 51 of these plus the GPT, so the full set is what a factory image considers present — but its `persist` is the factory template, not this unit's (`../../official-firmware/README.md`).

## 4. Stock behaviour

### How the previous port changed the layout, and why

`../../ubuntu-thinksmart/partitions/ubuntu_layout.sfdisk`: p1-p23 unchanged; `system` (p24) grows from 3145728 to **14280671** sectors starting at the same 923648; `persist` moves to **p27** at 15204319 (right at the disk end); everything else is deleted. It is a single rootfs plus the boot chain.

Net result: ~6.8 GiB single filesystem, which is the size the prior port actually ran Plasma Mobile in, so it is not theoretical.

The cost: no `vendor` (Linux does not need it, but its firmware is a second copy of the `modem`/`dsp` blobs — acceptable since `modem`/`dsp` are preserved), no second 32 MiB `recovery` (fine — EDL is the recovery path), and the loss of `syscfg`/`mcfg`/`apdp`/`msadp`.

## 5. Mainline state

Mainline does not care about the layout beyond what lk2nd hands over. The DTS has the aliases `mmc0 = &sdhc_1`, `mmc1 = &sdhc_2` so the rootfs is always `mmcblk0` despite the Wi-Fi card.

## 6. Gap and plan

The layout comes first, then the steps that prove it.

### Step 1: proposed layout for this port

Keep p1-p23 byte-identical, plus `persist` and the four small config partitions; one rootfs; `boot` stays p21 at 32 MiB for lk2nd's `extlinux.conf`.

| New | start | size | name |
| --- | --- | --- | --- |
| p1-p23 | as stock | as stock | unchanged |
| p24 | 923648 | **14268416** (6.80 GiB) | `root` |
| p25 | 15192064 | 65536 | `persist` |
| p26 | 15257600 | 1024 | `syscfg` |
| p27 | 15258624 | 8192 | `mcfg` |
| p28 | 15266816 | 512 | `apdp` |
| p29 | 15267328 | 512 | `msadp` |

Arithmetic and alignment checked: `root` ends at 15192063 so `persist` starts on a 2048-sector boundary; `msadp` ends at 15267839, leaving 2015 sectors of slack before `last-lba` 15269854 and the backup GPT. `new-last-lba` in the generated table must be set to 15267839, not inherited. Tail sizes are byte-identical to the stock partitions by name, so restoring any of them is a straight `dd` of the backed-up image.

`resource` (356 MiB) is deliberately **not** kept: it holds DSP resource-manager blobs from the Android build and is the largest single win after `userdata`. Flagged as an open question in case the ADSP firmware turns out to want something from it.

`/boot` filesystem: 32 MiB, and lk2nd's extlinux reader handles FAT32 and ext2/3/4. Use **ext2** (no journal churn on a 32 MiB partition) or FAT32; never ext4 with a journal at this size. Kernel, DTB and `extlinux/extlinux.conf` live in the root of that partition.

1. Generate the new GPT with `sfdisk` from the table above and store it as `layout_arch.sfdisk` next to the stock one. Test: `sfdisk --verify`, then diff the retained partitions against `stock_layout.sfdisk`.
2. Prove the restore path **before** using the new layout: write the stock GPT back and confirm `printgpt` through EDL matches `backup-20261029/by-name.txt`. This is GOAL milestone 1/2 and the brief's "tested way back".
3. Restore `persist` from `../../backup-20261029/partitions/persist.img.zst` into the new p25 *before* first boot, per the README rule. Verify with the on-device SHA-256 recorded in the backup.
4. Write `root`, format ext4, `boot` ext2, populate `extlinux.conf`, and keep a second copy of lk2nd in `boot` until the system is stable.
5. Sizing check against the real Omarchy package list on the laptop, not on the device: `pacman -S --print` the install set and compare with 6.80 GiB and 2 GiB RAM.
6. Escape hatch: `recovery` is gone, so EDL + the backup must be usable from any state. Rehearse one EDL read and one EDL GPT write before the first Arch boot.

## 7. Risks

- **`persist` loss** destroys Wi-Fi/BT MACs and sensor calibration. Backed up, and must be restored into the new partition before first boot.
- **Partition-table writes** via EDL can leave an unbootable unit if interrupted; the unit only recovers through EDL, and the bootloader is locked.
- `devinfo` holds the unlock flags; a GPT rewrite that shifts it breaks unlock state. It is at p23 and stays put.
- `splash` is Lenovo's boot logo; dropping it makes lk2nd/mainline boot visually blank (cosmetic, but it is 11 MiB and stays).
- `system`, `vendor`, `cache`, `oem` are all read-write mounted on stock; formatting them is destructive but they hold nothing unique.

## 8. Open questions

- Does anything in `aboot`/TZ read `syscfg`, `mcfg`, `apdp` or `msadp` before Linux? Keeping them is cheap insurance, but they should be proven droppable or not.
- Is `resource` needed by the ADSP firmware once the DSP is brought up on mainline?
- Which filesystems does the lk2nd build in `prebuilt/lk2nd.img` actually include?
- Does Omarchy fit in 6.80 GiB with the package set we want, or does the layout need to drop `splash`/`recovery` too?

## 9. Sources

- `evidence/stock-emmc-identity-20261030.txt`, `evidence/stock-live-layout-20261030.txt`.
- `../../backup-20261029/stock_layout.sfdisk`, `gpt_primary.bin`, `gpt_backup.bin`, `by-name.txt`, `partitions/`.
- `../../ubuntu-thinksmart/partitions/{ubuntu_layout.sfdisk,LAYOUT.md}`, `FLASHING.md`.
- `../../official-firmware/README.md` and `rawprogram_unsparse.xml` (Zoom 210602.2103).
- `../_inventory/ANALYSIS.md`; `storage-emmc/BRIEF.md`.
