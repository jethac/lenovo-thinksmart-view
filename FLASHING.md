# Flashing

**To install, use the installer: `install/install.sh` ([install/README.md](install/README.md)).** It takes a stock unit, or one already on the stage-B layout, to the stage-B layout running the Straylight image, in one EDL session. It checks the HWID and PK hash, classifies the table, backs the unit up to `units/<serial>-<date>/` (verified) before any write, repartitions from the unit's own table, writes `system` and `boot` with read-back, resets, and checks the first boot. `--dry-run` prints every read and write; `--restore units/<dir>` puts the backed-up table and partitions back. Enter EDL as in step 1 below first.

The rest of this file is background: how stage A was done by hand on HUA0BMNX (2026-10-30), with the stock table, and the stage-B notes. The stage-B repartition itself was done from the running system (`streams/stage-b/RUNBOOK.md`). The installer uses the same `tools/edl` setup, the same programmer choice, and the stage-B tools (`make-layout.py`, `make-gpt-blobs.py`). It addresses the eMMC by raw sector (`rs`/`ws`) instead of by partition name, and resets with `reset --resetmode=reset`.

The current image is 3 GiB and no longer fits the stock `system` (1.5 GiB), so the stage-A steps below now apply only to a unit that is already on the stage-B table.

## Stage A (by hand, background)

First Linux boot on the ThinkSmart View (`HUA0BMNX`) **without changing the partition table**. lk2nd goes into `boot`, our image into `system`. Everything else on the eMMC stays as it is: GPT, bootloaders, `devinfo`, `persist`, `modemst*`, `fsg`, `modem`, `dsp`, `userdata`. Repartitioning (root grows to about 6.7 GiB for the speech models) is stage B, done later from the running system.

Run every command from `/home/jethac/Projects/lenovo-8`. `EDL` below means:

```sh
EDL="tools/edl/.venv/bin/python tools/edl/edl.py"
```

### What gets written

| Partition | File | SHA-256 |
| --- | --- | --- |
| `boot` (p21, 32 MiB) | `lk2nd/out/lk2nd.img` | see `lk2nd/out/lk2nd.img.sha256` |
| `system` (p24, 1.5 GiB, 3145728 sectors) | `rootfs/out/thinksmart-alarm-system.img` | see `rootfs/out/thinksmart-alarm-system.img.sha256` |

Both are checked again right before writing (step 3).

### 0. Before starting

- [ ] Backup verified: `backup-20261029/` and `synology-nas:/volume1/NetBackup/ThinkSmart_View-HUA0BMNX-before-omarchy-20261029/` (50 partitions, on-device SHA-256 matched).
- [ ] Nothing else is using the tablet (analysis work finished).
- [ ] Cable: **USB-A to USB-C**, from a USB-A port (the Anker hub), into the USB-C port behind the plug on the right side (portrait, camera top left). A laptop USB-C port will not work: this port has no CC negotiation (`devices/usb/ANALYSIS.md`).
- [ ] Barrel power connected.
- [ ] Optional: Wi-Fi PSK injected (`rootfs/scripts/inject-wifi.sh --ssid yareyare-xd-mesh --psk -` on the image). Not needed for stage A; USB networking and adb work without Wi-Fi.

Prepare the rollback images now, so they are ready if needed:

```sh
mkdir -p flash-work && cd flash-work
for p in boot system; do zstd -dc ../backup-20261029/partitions/$p.img.zst > stock-$p.img; done
grep -E '  (boot|system)\.img$' ../backup-20261029/partitions/SHA256SUMS.device
sha256sum stock-boot.img stock-system.img     # must match the two lines above
cd ..
```

### 1. Enter EDL (also the first step for the installer)

Either, from the running LineageOS (root adb):

```sh
adb -s HUA0BMNX reboot edl
```

or by hand: unplug the barrel jack, hold **Vol+ and Vol-**, plug the barrel jack back in, keep holding for 5 to 10 s. The screen flashes and stays dark.

Check: `lsusb | grep 05c6:9008` shows `Qualcomm ... QDL mode`. If it shows `05c6:900e` instead, that is diagnostics mode, not EDL: unplug, and retry by hand.

### 2. Identify the chip and choose the programmer

```sh
$EDL printgpt 2>&1 | tee flash-work/edl-printgpt.log
grep -iE 'hwid|pk_hash|loader' flash-work/edl-printgpt.log
```

`edl` prints the chip's HWID and PK hash, picks a loader, and prints the GPT. Lenovo's own programmers are in `official-firmware/firehose/` (three builds of `BOOT.BF.3.3-00228`; the standalone one is also in edl's collection as `lenovo_motorola/000660e160008000_b9eca30dfea46934_fhprg_peek.bin`). If edl's automatic choice fails, rerun with `--loader=official-firmware/firehose/prog_emmc_firehose_8953_ddr.mbn`, then the Zoom and Teams builds. A rejected programmer does no harm; unplug and re-enter EDL.

Checks:

- [ ] GPT matches the stock layout: `boot` start 790528 size 65536, `system` start 923648 size 3145728 (compare with `backup-20261029/stock_layout.sfdisk`).

Read-back test (proves reads work and the firehose talks to the right disk):

```sh
$EDL r devinfo flash-work/devinfo-readback.img
sha256sum flash-work/devinfo-readback.img
grep '  devinfo.img$' backup-20261029/partitions/SHA256SUMS.device   # must match
```

Stop here if anything does not match.

### 3. Write lk2nd

```sh
(cd lk2nd/out && sha256sum -c lk2nd.img.sha256)
$EDL w boot lk2nd/out/lk2nd.img
$EDL r boot flash-work/boot-readback.img
cmp -n $(stat -c%s lk2nd/out/lk2nd.img) lk2nd/out/lk2nd.img flash-work/boot-readback.img && echo "boot OK"
```

### 4. Write the system image

```sh
(cd rootfs/out && sha256sum -c thinksmart-alarm-system.img.sha256)
$EDL w system rootfs/out/thinksmart-alarm-system.img
$EDL r system flash-work/system-readback.img
cmp rootfs/out/thinksmart-alarm-system.img flash-work/system-readback.img && echo "system OK"
```

The image is exactly the size of `system`, so `cmp` compares the whole partition.

### 5. Boot

```sh
$EDL reset
```

Expected on screen: Lenovo logo (from `aboot`), possibly a brief lk2nd screen, then the ai& splash, then the ai& idle screen. If the panel does not come up, boot carries on without it.

On the laptop, within about 30 s:

```sh
ip -br link | grep -iE 'usb|enx|enp.*u'     # new NCM interface
ping -c 3 172.16.42.1
ssh jethac@172.16.42.1
adb devices -l                              # ThinkSmart_View
```

The USB serial console is the ACM port (`/dev/ttyACM0` on the laptop, 115200).

### If it does not boot

- **No USB device at all, screen dark:** lk2nd or the kernel did not start. Enter EDL by hand (step 1) and roll back `boot`, or look at the serial console on the USB-C SBU pins (1.8 V; `devices/debug-uart/ANALYSIS.md`).
- **lk2nd starts but Linux does not:** lk2nd has a fastboot menu (hold Vol- while powering on); `fastboot` through lk2nd can rewrite `system` without EDL. Not yet tried on this unit.
- **Roll back to the as-received system:**

  ```sh
  $EDL w boot flash-work/stock-boot.img
  $EDL w system flash-work/stock-system.img
  $EDL reset
  ```

  `userdata` was never touched, so LineageOS comes back as it was.

## After stage B (done on HUA0BMNX, 2026-10-31)

The partition table is no longer stock: `system` (p24) is 6.80 GiB, `persist`, `syscfg`, `mcfg`, `apdp` and `msadp` moved to the end of the disk, and 22 Android partitions are gone (`streams/stage-b/`). This runbook still works on that layout: `system` starts where it did, and the image grows its root to fill the partition on first boot (`tsv-growroot`). `printgpt` in step 2 now shows 29 partitions; check `system` start 923648 size 14264320 instead of the stock values.

Going back to stock is the stock GPT plus partition images over EDL (`streams/stage-b/RUNBOOK.md`, Rollback).
