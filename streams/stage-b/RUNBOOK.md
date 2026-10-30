# Stage B runbook: grow root by repartitioning, from the running system

Grows the GPT `system` partition (p24) from 1.5 GiB to 6.80 GiB and root from 1.37 GiB to 6.68 GiB, keeping p1-p23 exactly as they are and moving `persist`, `syscfg`, `mcfg`, `apdp` and `msadp` to the end of the disk. Everything is done from the running Arch system over adb. EDL is the fallback and the deep rollback only.

**Needs the user's explicit approval** before step 4 (the first write). Steps 1-3 are read-only.

## What changes

| | Stock (now) | After |
| --- | --- | --- |
| p1-p23 (`modem` ... `devinfo`) | as stock | **byte-identical GPT entries, contents untouched** |
| p24 `system` | 923648 + 3145728 (1.5 GiB) | 923648 + **14264320** (6.80 GiB), same name, UUID, type, attrs |
| p25 | `vendor` | `persist` at 15187968 (32 MiB) |
| p26-p29 | `cache`, `persist`, `misc`, `keystore` | `syscfg` 15253504, `mcfg` 15255552, `apdp` 15263744, `msadp` 15265792 |
| p30-p51 | `config` ... `userdata` | gone (22 entries: `vendor`, `cache`, `misc`, `keystore`, `config`, `oem`, `limits`, `mota`, `dip`, `mdtp`, `lksecapp*`, `cmnlib*`, `cmnlib64*`, `keymaster*`, `dpo`, `logdump`, `resource`, `userdata`) |
| GPT header | label-id `98101B32-...`, 52 entries, first-lba 34, last-lba 15269854 | same, 29 entries used |

Full table: `layout.sfdisk` (generated from `backup-20261029/stock_layout.sfdisk` by `make-layout.py`). Every moved partition keeps its stock size, type GUID, UUID and attributes, and starts on a 1 MiB boundary. The tail ends at 15267840, leaving 2015 sectors before the backup GPT entries at 15269855. `last-lba` stays 15269854; it describes the usable area of the disk, not the end of the last partition.

The bytes written to the disk are:

1. The five tail partitions, copied from their stock places to their new places. The destinations are inside stock `userdata`, which Linux never opens.
2. The two GPT copies, as pre-built blobs in Lenovo's own structure (stock protective MBR, backup entry array at 15269855): `gpt/new-primary.bin` (LBA 0-33) and `gpt/new-backup.bin` (LBA 15269855-15269887).
3. After the reboot, `tsv-growroot` rewrites the MBR inside p24 and grows ext4.

Nothing inside p1-p23 or the first 1.5 GiB of p24 is written.

## Why from the running system and not over EDL

- Root lives in p24, whose start does not move. The kernel's partition view is left as it is: no re-read, and the `udev` re-read attempt fails with `EBUSY` while p24 is open. So the running system keeps working until the reboot.
- Every write is a plain `dd` of a file whose SHA-256 is known, and is read back with `O_DIRECT` and checked before going on.
- The tail is copied **before** the GPT changes, so there is never a table that points at an empty `persist`.
- Up to the grow step, rollback is a second `dd` of the stock blobs from the same shell, with no EDL.
- EDL needs a button dance or `reboot edl`, takes the device offline during the work, and is reserved for the integrator. It stays as the recovery path (below).

## Prerequisites

- [ ] The user's approval, relayed by the integrator (the approval request in `NOTES.md`).
- [ ] The device is on the baseline kernel and userspace, reachable with `adb -s feb0bd1f028e4cb0`, with barrel power. Nothing else is running on it.
- [ ] `backup-20261029/` is present, and the NAS copy is reachable (`synology-nas:/volume1/NetBackup/ThinkSmart_View-HUA0BMNX-before-omarchy-20261029/`).
- [ ] `flash-work/stage-b/persist-live-20261030.img` (sha256 `19c5dd29...d6ce2`) is present. See NOTES.md for why `persist` is checked against this and not the backup image.
- [ ] EDL recovery ready, in case the unit does not boot: `tools/edl` works (FLASHING.md), and `flash-work/stage-b/` holds the stock GPT blobs (step 1 copies them there).

## Procedure

All commands run on the laptop from `/home/jethac/Projects/lenovo-8`. The whole run, including the reboot, takes one lock:

```sh
cd /home/jethac/Projects/lenovo-8
flock -w 1800 .device.lock bash          # everything below runs in this shell
A="adb -s feb0bd1f028e4cb0"
SB=/var/lib/tsv/stage-b
```

### 1. Build and rehearse (laptop, about 1 min)

```sh
streams/stage-b/make-bundle.sh                  # -> streams/stage-b/work/bundle
streams/stage-b/rehearse.sh                     # ends with "rehearsal OK"
cp streams/stage-b/work/bundle/gpt/*.bin flash-work/stage-b/
(cd flash-work/stage-b && sha256sum *.bin | tee gpt-blobs.sha256)
```

Check: `make-bundle.sh` prints `selftest: stock backup reproduced byte for byte from stock primary`.

### 2. Push the bundle (read-only on the device apart from the bundle directory)

```sh
$A shell "mkdir -p $SB"
$A push streams/stage-b/work/bundle/. $SB/
$A shell "cd $SB && sha256sum -c SHA256SUMS.bundle"      # all OK
```

### 3. Precheck (read-only, about 3 s)

```sh
$A shell "$SB/stage-b.sh precheck"
```

Expected: root on `/dev/loop0p2` backed by `/dev/mmcblk0p24`, `GPT on disk: stock (byte-identical to backup-20261029)`, and `sha256 OK` for all five tail partitions at their stock places. Any `STOP:` line ends the run. Nothing has been written.

### 4. Copy the tail partitions (writes 39 MiB inside stock `userdata`, about 5 s)

```sh
$A shell "$SB/stage-b.sh copy-tail"
```

Expected: five `copied ... read back sha256 OK` lines. If this fails, nothing that is in use has been touched and the stock table still holds: stop and report.

### 5. Write the new GPT (about 1 s)

```sh
$A shell "$SB/stage-b.sh write-gpt"
$A shell "sfdisk -d /dev/mmcblk0" > streams/stage-b/work/device-new-layout.sfdisk
```

Expected: `writing backup GPT`, `writing primary GPT`, then `GPT on disk: new layout, both copies byte-identical, matches layout.sfdisk`. The running system is unaffected: `lsblk` still shows the old 51 partitions until the reboot.

The backup copy goes first. If the write stops between the two copies, the primary is still stock and valid, and the disk reads as stock (rehearsed). The primary is one 17 KiB write.

**Optional drill (GOAL "Restoring stock ... tried at least once"):**

```sh
$A shell "$SB/stage-b.sh rollback-gpt"   # stock again, byte-identical to backup-20261029
$A shell "$SB/stage-b.sh precheck"       # passes as at step 3
$A shell "$SB/stage-b.sh write-gpt"      # new layout again
```

### 6. Reboot into the new table (about 40 s)

```sh
$A shell sync
$A reboot
timeout 180 sh -c "until $A shell true 2>/dev/null; do sleep 3; done" && echo back || echo "NOT BACK"
```

If it is not back within three minutes: **stop, do not retry, report** (WORKSTREAMS.md). Recovery is EDL by the integrator (below). The stock contents of every dropped partition are still in place at this point, so writing the stock GPT back restores the pre-stage-B state exactly.

`/var/lib/tsv/growroot.done` exists from the first boot, so `tsv-growroot` does **not** run on this boot. That is deliberate: the boot chain is proven on the new table before anything is grown.

### 7. Post-boot checks (read-only, about 3 s)

```sh
$A shell "$SB/stage-b.sh postboot"
$A shell "lsblk -o NAME,START,SIZE,PARTLABEL /dev/mmcblk0 | tail -8; df -h /"
```

Expected: the new GPT is still on disk; the kernel sees 29 partitions; p24 and `/dev/loop0` are 14264320 sectors; `persist`, `syscfg`, `mcfg`, `apdp` and `msadp` by label are at their new starts with `sha256 OK`; root is still 1.4G. USB networking, ssh and adb work.

Last chance to go back without EDL: `$A shell "$SB/stage-b.sh rollback-gpt" && $A reboot`.

### 8. Grow root (POINT OF NO RETURN, 10-60 s)

```sh
$A shell "$SB/stage-b.sh grow"
$A shell "df -h /; tune2fs -l /dev/loop0p2 | grep -E 'Block count|Reserved block'"
```

This removes the `growroot.done` marker and runs `tsv-growroot.service`. MBR partition 2 inside p24 grows from 2881536 to 14000128 sectors, and ext4 grows online from 360192 to 1750016 blocks (6.68 GiB). The group descriptors still fit in the existing GDT block (11 to 54 groups, 64 per block), so the online resize needs no new GDT blocks. Expected `df`: about 6.5G size, 5.3G free.

Once root grows over the old `vendor` ... `userdata` extents (the old `persist` place included), the stock table can no longer simply be written back: p24 would be smaller than the filesystem inside it.

Optional: `tune2fs -m 1 /dev/loop0p2` reserves 67 MiB for root instead of 334 MiB.

### 9. Record

```sh
$A shell "dd if=/dev/mmcblk0 bs=512 count=34 status=none" > flash-work/stage-b/device-gpt-primary-after.bin
$A shell "dd if=/dev/mmcblk0 bs=512 skip=15269855 count=33 status=none" > flash-work/stage-b/device-gpt-backup-after.bin
cmp flash-work/stage-b/device-gpt-primary-after.bin flash-work/stage-b/new-primary.bin
cmp flash-work/stage-b/device-gpt-backup-after.bin flash-work/stage-b/new-backup.bin
exit                                         # releases the lock
```

## Rollback

| Where it stopped | State | Way back |
| --- | --- | --- |
| Steps 1-3 | nothing written | nothing to do |
| Step 4 | stock GPT, 39 MiB of unused `userdata` overwritten | nothing to do (Android `userdata` is not used by Linux) |
| Step 5, before reboot | new GPT on disk, kernel on the old view | `stage-b.sh rollback-gpt` (rehearsed; byte-identical stock blobs) |
| Step 6, it boots | new GPT, nothing grown | `stage-b.sh rollback-gpt`, reboot |
| Step 6, it does not boot | new GPT, nothing grown | EDL, stock GPT blobs only (below). Every partition's contents are still where the stock table expects them |
| After step 8 | grown root | stay on the new layout. To go back to stock: EDL, stock GPT, then `system` (image or `system.img.zst`), `persist` (`persist-live-20261030.img`) and any other partition from `backup-20261029/partitions/` |

### EDL (integrator only)

Enter EDL as in FLASHING.md step 1, then:

```sh
EDL="tools/edl/.venv/bin/python tools/edl/edl.py"
$EDL printgpt                                                      # see which table is there
$EDL ws 15269855 flash-work/stage-b/stock-backup.bin               # backup copy first
$EDL ws 0 flash-work/stage-b/stock-primary.bin
$EDL rs 0 34 flash-work/stage-b/edl-readback-primary.bin
$EDL rs 15269855 33 flash-work/stage-b/edl-readback-backup.bin
cmp flash-work/stage-b/edl-readback-primary.bin backup-20261029/gpt_primary.bin
cmp flash-work/stage-b/edl-readback-backup.bin backup-20261029/gpt_backup.bin
$EDL printgpt                                                      # 51 partitions, as by-name.txt
$EDL reset
```

The same commands with `new-*.bin` write the new layout over EDL (option b). After EDL writes of the new layout, write the tail too: `$EDL w persist flash-work/stage-b/persist-live-20261030.img`, plus `syscfg`, `mcfg`, `apdp` and `msadp` from `backup-20261029/partitions/` (decompressed). `edl w <name>` uses the table that is on the disk at that moment.

After a full return to stock, partitions that were grown over need their images back: `$EDL w system flash-work/stock-system.img` (or the Arch image), `$EDL w persist flash-work/stage-b/persist-live-20261030.img`, and `vendor`, `cache`, `oem`, `resource`, `logdump`, `mdtp` and so on from `backup-20261029/partitions/`. `userdata` was never backed up as an image and is not needed for Linux.

## Timings

| Step | Device time | Notes |
| --- | --- | --- |
| 1 build + rehearse | (laptop) about 60 s | rehearsal 26 s on the laptop |
| 2 push | under 5 s | 70 KiB |
| 3 precheck | about 3 s | eMMC reads at 95 MB/s (measured, `O_DIRECT`) |
| 4 copy-tail | about 5 s | 39 MiB read + synchronous direct write + read back |
| 5 write-gpt | about 1 s | 2 x 17 KiB |
| 6 reboot | about 40 s to adb | measured `systemd-analyze`: 3.3 s kernel + 7.6 s userspace, plus aboot and lk2nd |
| 7 postboot | about 3 s | |
| 8 grow | 10-60 s | online resize2fs on eMMC |
| **Total** | **about 5 minutes** hands-on, about 15 s of writes | |

## Point of no return

**Step 8, `stage-b.sh grow`.** Before it, every state goes back to stock by writing the two stock GPT blobs, from the running system (steps 5-7) or over EDL (if step 6 does not boot). Neither needs any partition image. After it, root covers the old partitions' extents, and returning to stock means reflashing through EDL from the backup.

The riskiest moment before that is the reboot in step 6. It is the first time `aboot` and lk2nd see a table without `vendor`, `misc`, `keymaster`, `cmnlib*` and the others. rickx's 25-partition layout on the same model (`devices/storage-emmc/evidence/ubuntu-rickx-gpt-sfdisk-20260528.txt`) boots without all of them. Ours keeps four more (`syscfg`, `mcfg`, `apdp`, `msadp`). If it does not boot, the recovery is the 2-blob EDL write.
