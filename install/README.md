# Installer: stock or stage-B unit to Straylight, in one EDL session

`install/install.sh` takes a ThinkSmart View CD-18781Y in EDL mode and leaves it on the stage-B
partition layout (`streams/stage-b`), running the Straylight image, with a verified backup of the
unit on the laptop. It handles:

- a **stock** unit: Lenovo's 51-partition table;
- an **already stage-B** unit, which gets a re-install;
- a unit left **half way** by an earlier run of this script (it resumes).

Anything else is refused before anything is written.

Run everything from the repository root. The unit has to be in EDL first (FLASHING.md step 1:
`adb reboot edl`, or Vol+ and Vol- while plugging in the barrel jack; `lsusb` shows `05c6:9008`).

```sh
install/install.sh --dry-run        # read-only: identify, classify, print every read and write
install/install.sh                  # prints the same plan, asks for the serial, then runs
```

| Path | What |
| --- | --- |
| `install/install.sh` | the installer: install, `--dry-run`, `--restore`, `--check-boot` |
| `install/tsvgpt.py` | GPT parsing and classification, the backup slicer and verifier, payload checks |
| `install/stock-gpt.layout` | the stock table's structure (names, places, sizes, types, attributes), without per-unit UUIDs |
| `install/mock-edl.py`, `install/mock-adb.sh` | stand-ins for edl and adb, backed by a disk image file, for the rehearsal |
| `install/rehearse.sh` | the rehearsal (below) |
| `units/<serial>-<date>/` | the per-unit backup and logs. Ignored by git, never leaves the laptop |
| `install/work/` | temporary files (`TMPDIR` is set here, because the laptop's `/tmp` is small) and the rehearsal. Ignored by git |

The new table comes from `streams/stage-b/make-layout.py` and `make-gpt-blobs.py`, the tools that
built the table that booted on HUA0BMNX on 2026-10-31. The installer runs them on the unit's own
stock table and does not carry a copy of them.

## What it does

The unit stays in EDL from the first read to the reset. Each step is a separate `edl` call
(`tools/edl`, loader picked automatically, as in FLASHING.md). bkerler/edl reconnects to the
running programmer, so there is no second Sahara upload and no button press. The only `edl`
commands used are `printgpt`, `rs` and `ws` (raw sectors, the installer's own offsets) and
`reset --resetmode=reset`. No partition is addressed by name, so nothing depends on which table
edl happens to read.

### 1. Preflight (read-only, about 30 s)

- **Tools and payload.** Checks the tools, the image and lk2nd against their `.sha256` files, and
  lk2nd's structure: an Android boot image with no QCDT, a BootSignature after the payload
  (`SIGN_BOOTIMG=1`), and the `SEANDROIDENFORCE` trailer. Checks the image's nested MBR: p1 is
  ext2 `tsv-boot` and p2 is ext4 `tsv-root`.
- **Identity.** `edl printgpt`. The Sahara HWID must be `0x000660e160008000` and the PK hash
  `0xb9eca30d…bb70c14`, both in full (the values in `flash-work/edl-printgpt.log` from stage A).
  The values are written to `units/.edl-session`, keyed by the eMMC serial. If the programmer is
  already running from an earlier call in the same EDL session, Sahara prints nothing. The
  installer then accepts that session file, and only for the same eMMC serial; otherwise it asks
  for the unit to be re-entered into EDL.
- **Table.** Reads both GPT copies raw: LBA 0+34 and LBA total-33+33. Reads the serial number
  from `devinfo`: sector 921600, offset 228, after Lenovo's `ANDROID-BOOT!` header. This is the
  `androidboot.serialno` the stock kernel gets, and it is also the unit's folder name and the
  confirmation word. Then each copy is classified:
  - **stock**: header geometry (52 entries, first-lba 34, last-lba = total-34, backup entries
    at last-lba+1), Lenovo's protective MBR, and every entry's name, start, size, type and
    attributes as in `stock-gpt.layout`. UUIDs may be anything. `userdata` runs to last-lba.
  - **stage-B**: the same, against the make-layout transformation of that structure.
  - **invalid**: bad signature or CRC.

  The unit is *stock* or *stage-B* only if both copies are of that kind and the backup copy is
  exactly the primary's mirror (the `make-gpt-blobs.py` construction). One copy rewritten or torn
  is *half*. Anything else is refused.

### 2. Plan and confirmation

Prints every read and write with LBA, sector count and size, then an estimate of the time.
Nothing goes further until the unit's serial number is typed. `--dry-run` stops here. Every read
and write is logged with its duration and edl's own MB/s figure to
`units/<serial>-<date>/install-*.log` and `edl-*.log`. Every write is first recorded in
`writes.tsv`, with its sha256.

### 3. Backup, before any write (stock unit: about 2.5 min)

Everything except `userdata` is backed up, plus `system` unless `--no-system-backup` is given.
The partitions are merged into contiguous regions; gaps of up to 128 MiB are read too. On a
stock unit that is one `rs` of LBA 131072+6759440 (3.22 GiB). On a stage-B unit it is
131072+15135232 (7.2 GiB, mostly `system`).

On the laptop each region is cut into `partitions/<name>.img.zst`. The gaps between partitions
are kept as well: as `gaps/<lba>.img.zst` when they hold data, as an entry in `gaps.tsv` when
they are zero. The script then writes `SHA256SUMS` (of the uncompressed data), `partitions.tsv`
(each entry with its UUID), and the two raw GPT copies in `gpt/`. The backup is verified by
decompressing every file from the laptop and checking it against `SHA256SUMS`. `backup.ok` is
written only after that. In the rehearsal, the backup of HUA0BMNX comes to 578 MiB.

**Why everything, and not a short list:**

- Per-unit data that nothing else can recreate:
  - `persist`: Wi-Fi and Bluetooth MACs, sensor calibration;
  - `modemst1`, `modemst2`, `fsg`, `fsc`: the modem file system;
  - `devinfo`: serial number and lock state;
  - `DDR`: DDR training;
  - `ssd`, `sec`, `config`, `misc`, `keystore`, `syscfg`, `mcfg`, `apdp`, `msadp`, `dip`,
    `limits`, `mota`, `dpo`.

  Lenovo's own packages write none of these: they have no file for them in
  `rawprogram_unsparse.xml`, or, for `persist`, only a factory template.
- What the install overwrites or drops: `boot`, `system`, and everything from LBA 4069376 to
  the end of the old `resource`. That range is `vendor`, `cache`, `persist`, `misc`,
  `keystore`, `config`, `oem`, `limits`, `mota`, `dip`, `mdtp`, `syscfg`, `mcfg`,
  `lksecapp*`, `cmnlib*`, `keymaster*`, `apdp`, `msadp`, `dpo`, `logdump` and `resource`. The
  image and then `tsv-growroot` cover all of it.
- The bootloaders (`sbl1`, `rpm`, `tz`, `devcfg`, `aboot`, `cmnlib*`, `keymaster*`) and `modem`
  and `splash` on HUA0BMNX are **not** the ones in either downloadable Lenovo package (Zoom
  210602, Teams 210228). Only `dsp`, `sec`, `lksecapp` and `mdtp` match. A unit's own backup is
  the only way back to that unit's stock state, and these partitions cost little: about 200 MiB
  in total, 8 s.

Cost over EDL, at the stage-A figure of 27 MB/s:

| Unit | With `system` | Without (`--no-system-backup`) |
| --- | --- | --- |
| stock | 3.22 GiB, about 2 min 10 s | 1.72 GiB, about 1 min 10 s |
| stage-B | 7.2 GiB, about 4 min 50 s | about 0.5 GiB, about 20 s |

On a stage-B unit, `system` is the running install, including its Wi-Fi profile.

### 4. Repartition, if the unit is stock (about 15 s)

- **This unit's table.** The unit's own two GPT copies go onto a sparse file of the unit's size.
  `sfdisk -d` reads them, `make-layout.py` transforms the dump, `sfdisk` writes the result, and
  `make-gpt-blobs.py --pmbr` turns it into Lenovo-structured blobs. `make-gpt-blobs.py
  --selftest` must reproduce the unit's stock backup copy from its primary byte for byte.
  The script then checks that the new table classifies as stage-B, and that every kept or
  moved entry has the unit's own UUID, type and attributes, the stock size (except `system`),
  and the same disk GUID. For HUA0BMNX the result is byte-identical to
  `flash-work/stage-b/new-*.bin`, the blobs it booted with.
- **Tail.** The script decompresses `persist`, `syscfg`, `mcfg`, `apdp` and `msadp` from
  *this* run's backup, read from *this* unit minutes earlier, and checks them against
  `SHA256SUMS`. They are packed at their new offsets into one 38.3 MiB buffer for LBA
  15187968-15266303, which is inside the stock `userdata`, and written with one `ws`. The script
  reads it back and compares. If the run resumes with an older backup while the table is still
  stock, each source partition is first read again at its stock place and must still equal the
  backup. A unit that ran Android in between therefore needs `--fresh-backup`.
- **GPT.** The backup copy is written first, then the primary, and each is read back and
  compared. Both are read again, compared, and classified as stage-B at the end.

The tail goes before the GPT, as in the stage-B runbook. No table ever points at a `persist`
that has not been written yet. Until the primary is written, the disk reads as stock.

### 5. Install (about 4.5 min)

- `system`: the image (3 GiB, 6291456 sectors) to LBA 923648. It is read back and compared,
  then recorded in `progress`.
- `boot`: lk2nd, padded to whole sectors, to LBA 790528. It is read back and compared. It goes
  last because it is the small switch from the old system to Straylight.
- `edl reset --resetmode=reset`, then `install.done`.

The checks use read-back. There is no hash command: bkerler/edl has no command for the
firehose `getsha256digest`, and this unit's programmer lists no supported functions
(`printgpt` log). Sending it as raw XML is untested on the unit, so read-back is the proven path
(2 min for the image).

### 6. First boot (about 1 min)

The script waits up to 240 s for adb with `model:ThinkSmart_View`, then polls a report until
`tsv-growroot` is done and systemd has settled. It checks:

- the kernel sees 29 partitions and p24 at 14264320 sectors;
- root (`/dev/loop0p2`) has grown to p24 minus 264192 sectors (14000128, 6.68 GiB);
- the system state is `running`;
- `sshd`, `NetworkManager`, `tsv-usb-gadget`, `tsv-usb-dhcp`, `tsv-adbd` and the four
  `straylight-*` units are active;
- the five tail partitions by label hash to the values in the backup.

Run it again later with `--check-boot units/<serial>-<date>`. If nothing comes up within the time
limit: stop, do not retry, see FLASHING.md "If it does not boot".

### Totals for a stock unit

| Part | Time |
| --- | --- |
| Preflight, plan | 0.5 min |
| Backup (with `system`) + compression and read-back on the laptop | 2.5 min |
| Tail + GPT | 0.3 min |
| `system` write + read-back | 4 min |
| `boot`, reset | 0.2 min |
| **EDL total** | **about 7.5 to 8 min** (20 `edl` calls, 6.3 GiB read, 3.0 GiB written) |
| First boot to the checks | about 1 min |

These are estimates. The only EDL speed measured on this unit comes from stage A (2026-10-30):
`w system` and `r system` of 1.5 GiB each, plus two edl start-ups, finished within 121 s. That
makes at least 26.6 MB/s on average across a write and a read. The 5 s per call is a planning
figure. The first real run logs the true numbers.

## Resuming

Every step works out from the disk where an earlier run stopped:

- **Table.** Each GPT copy is compared with the unit folder's saved stock copy and its planned
  new copy. A run is resumed only from a folder that has a backup, has logged at least one
  write, and explains the table on disk. Otherwise a stock or stage-B unit gets a new backup
  and folder.
- **Tail and boot.** These are read first. If they already hold the bytes, the write is skipped.
- **System.** Recorded in `progress` (image sha256 and LBA) once read back, so a resume does not
  read 3 GiB to find out.

Rehearsed below: a write that fails, and writes torn half way (cable pulled) for the primary GPT
and for `system`.

## Restore

```sh
install/install.sh --restore units/HUA0BMNX-20261031 [--reset]
```

The unit's serial must match the folder. The backup is decompressed and checked first. Then the
script writes back everything the install can have touched, using the folder's own table:

- `boot`;
- every partition and every gap from LBA 923648 on (for a stock folder: `system` and p25-p50
  except `userdata`), each read back and compared;
- the GPT backup copy, then the primary.

At the end both copies must be byte-identical to the saved ones. Restore is resumable: done
ranges are recorded in `restore.progress`. `userdata` is not in the backup. After a restore to
stock, Android needs a factory reset of `userdata`.

## Rehearsal

```sh
install/rehearse.sh          # about 11 min; log in install/work/rehearsal/rehearsal.log
```

No device is involved. The script builds a full-size image of HUA0BMNX's eMMC (15269888
sectors) from `backup-20261029`: both GPT copies, all 50 backed-up partitions at their stock
offsets, and random data at the start of `userdata` and where the tail goes. `mock-edl.py` serves
the edl commands from that file. It prints the same Sahara and storage lines, keeps the session
state, and can make a write fail, or tear it half way.

| Scenario | Checked |
| --- | --- |
| Other HWID, other PK hash, wrong serial typed, a foreign GPT | refused; disk image unchanged; no unit folder |
| `--dry-run` on stock | plan printed; only the three preflight reads reach the disk |
| 1. stock → installed | generated GPT byte-identical to `flash-work/stage-b/new-*.bin`; `layout.sfdisk` reproduced; backup: 50 partitions equal to `backup-20261029`'s SHA256SUMS; `sfdisk --verify` clean; `sfdisk -d` equals `layout.sfdisk`; the five tail partitions byte-identical to the backup at their new places; image at 923648, lk2nd at 790528; p1-p20 and p22-p23 untouched |
| first boot (offline) | nested MBR in p24; p1 ext2 with only `filetype,sparse_super,large_file`; `extlinux.conf` and every file it names present with inode flags 0x0; `root=LABEL=tsv-root` with `tsv_subpart=PARTLABEL=system` and exactly one `system` label; root ext4 `tsv-root` with systemd and `tsv-growroot` enabled and no `growroot.done`; the growroot `sfdisk ',+'` and `resize2fs` on a copy give 14000128 sectors / 1750016 blocks (6.68 GiB), with `e2fsck` clean before and after |
| `--check-boot` (adb mocked) | the report logic passes a matching report and catches a root that did not grow |
| 2. stage-B → installed again | table left alone; `system` (and its backup) redone; lk2nd skipped as already there; result byte-identical to scenario 1 |
| 3. stop after the tail copy | disk still stock; resumed in the same EDL session (programmer still running, so no Sahara identity: the session file is used); byte-identical to scenario 1 |
| 4. stop between the two GPT writes | disk is *half* (primary stock, backup new); resumed; byte-identical |
| 5. primary GPT write torn after 2 of 34 sectors | primary invalid (new header, stock entries: CRC), backup new: *half*; resumed; byte-identical |
| 6. `system` write torn | resumed; byte-identical |
| 7. restore to stock | GPT byte-identical to `backup-20261029/gpt_*.bin`; all 50 partitions equal to `backup-20261029`; LBA 0-6890511 (all but `userdata`, gaps included) byte-identical to the stock image; the installer sees `stock` again |

The rehearsal reads filesystems with `debugfs` at byte offsets rather than mounting them (no
root on the laptop). It cannot show anything about USB, the real programmer, the eMMC, aboot,
lk2nd or the kernel.

## Not proven until it runs on a unit

- `rs` and `ws` at raw offsets on this programmer. Stage A used `r`/`w` by name, and the
  stage-B GPT was written from Linux, not over EDL.
- The reconnect behaviour of edl over 20 calls in one session, and how long a call takes.
- Real EDL speeds (only the stage-A lower bound is known) and a 3.2 GiB single `rs`.
- The first boot from an EDL-written stage-B table. It is the same bytes that booted on
  HUA0BMNX, so the risk is low.
- Units other than HUA0BMNX:
  - the devinfo serial offset;
  - the same eMMC size (any size is handled in principle, but only 15269888 sectors has been
    seen);
  - stock tables whose bootloaders differ (the classification checks the table, not the
    bootloaders).
- The first-boot checks over real adb.
