# stage-b notes

> **2026-10-30: Omarchy dropped** (see `GOAL.md`). The repartition plan, runbook and rehearsal below still stand: the extra root space is now for the speech models. The Omarchy sizing, the `omarchy/` directory and `omarchy-size.py` are kept only as a record.

Repartition the eMMC so root can hold Omarchy, then install Omarchy (omarchy-arm) in a form that suits an 800x1280 portrait touch tablet with 2 GB of RAM.

## Done 2026-10-31

Run by the RUNBOOK, with one change: reboots used `systemctl reboot` and a new `/proc/sys/kernel/random/boot_id`, because `adb reboot` does not always reboot this device.

| Step | Result |
| --- | --- |
| Rehearsal on the laptop | `rehearsal OK`; stock blobs byte-identical to `backup-20261029` |
| Precheck | stock GPT; five tail partitions sha256 OK at their stock places |
| copy-tail | five copies read back sha256 OK at the new places |
| write-gpt | both copies written, byte-identical, match `layout.sfdisk` |
| Drill | rolled back to the stock GPT (verified), precheck passed, new GPT written again (verified) |
| Reboot on the new table | back in about 15 s; 29 partitions; tail partitions sha256 OK by label; system running |
| grow | MBR partition 2: 2881536 -> 14000128 sectors; ext4 online to 1750016 blocks; `df` 6.6G, 5.3G free; read-only fsck clean |
| Second reboot | clean, no failed units, sound card present |
| Record | GPT on disk byte-identical to `new-primary.bin` / `new-backup.bin` |

Note for checks after a reboot: the ADSP and the sound card come up about 22 s after boot.

## Status (2026-10-30)

| | |
| --- | --- |
| Layout | **done**: `layout.sfdisk`, verified with `sfdisk --verify` on a full-size image; kept entries diffed against stock |
| Procedure | **done**: from the running system (`stage-b.sh`, `RUNBOOK.md`); EDL as fallback and deep rollback |
| Rehearsal | **passes** end to end on the laptop (`rehearse.sh`, log in `work/rehearsal.log`) |
| On the device | **nothing written**. Read-only checks only (hashes, GPT read-back, `ext_csd`, `pacman -Q`) |
| Omarchy plan | **done** on the laptop: package set, sizes, fork patch, touch settings, install script. Not run on the device: no internet yet, and repartitioning comes first |
| Waiting on | the user's approval (request below); `wifi` for internet; the integrator for two kernel config options |

## Left on the device

Nothing. No files were pushed; the stage-B bundle goes to `/var/lib/tsv/stage-b` only when the procedure runs.

## Files

| File | What |
| --- | --- |
| `layout.sfdisk` | the new GPT, sfdisk dump format |
| `make-layout.py` | generates it from `backup-20261029/stock_layout.sfdisk` |
| `make-gpt-blobs.py` | turns the sfdisk result into Lenovo-structured GPT blobs; `--selftest` reproduces `gpt_backup.bin` from `gpt_primary.bin` byte for byte |
| `make-bundle.sh` | builds `work/bundle/` (script, both tables, stock and new blobs, expected tail hashes, checksums) |
| `stage-b.sh` | the on-device procedure: `precheck`, `copy-tail`, `write-gpt`, `verify-gpt`, `rollback-gpt`, `postboot`, `grow` |
| `rehearse.sh` | the whole procedure against a 15269888-sector sparse disk image |
| `RUNBOOK.md` | commands, checks, rollback per stage, EDL, timings |
| `omarchy-size.py` | offline dependency resolver and size calculator over pacman sync databases |
| `omarchy/tablet.packages`, `tablet.drop`, `tablet.add` | the tablet package set, and what was left out or added, with reasons |
| `omarchy/omarchy-arm-thinksmart.patch` | five small changes to omarchy-arm 579f15c6 (below) |
| `omarchy/install-omarchy.sh` | `preflight`, `dry-run`, `install`, `fixup` on the device |
| `omarchy/home/`, `omarchy/etc/` | Hyprland, shell, Chromium and SDDM settings for the tablet |
| `work/`, `downloads/` | ignored by git: rehearsal output, bundle, repo databases, omarchy-arm checkout |
| `flash-work/stage-b/` | ignored: `persist-live-20261030.img` (+ `.sha256`); GPT blobs are copied here by runbook step 1 |

## The layout

| # | name | start | size | from stock |
| --- | --- | --- | --- | --- |
| 1-23 | `modem` ... `devinfo` | as stock | as stock | byte-identical entries |
| 24 | `system` | 923648 | 14264320 (6.80 GiB) | grown; same start, name, UUID, type, attrs |
| 25 | `persist` | 15187968 | 65536 | moved from 5238784 |
| 26 | `syscfg` | 15253504 | 1024 | moved from 5835776 |
| 27 | `mcfg` | 15255552 | 8192 | moved from 5836800 |
| 28 | `apdp` | 15263744 | 512 | moved from 6029312 |
| 29 | `msadp` | 15265792 | 512 | moved from 6029824 |

- Header unchanged: label-id `98101B32-BBE2-4BF2-A06E-2BB33D000C20`, first-lba 34, last-lba 15269854, 52 entries.
- Tail partitions start on 1 MiB boundaries. Each 512 KiB / 256 KiB partition sits in its own 1 MiB slot. That costs 2 MiB against the storage analysis's table (`system` 14264320 instead of 14268416 sectors).
- The analysis's "`new-last-lba` must be set to 15267839" is not applied. `last-lba` is the usable area of the disk, which the backup GPT bounds. It stays 15269854, as stock and as rickx's working table have it.
- Diff against stock: 23 entries identical (full line); the six above differ only in `start` (and `size` for `system`); 22 dropped (`vendor`, `cache`, `misc`, `keystore`, `config`, `oem`, `limits`, `mota`, `dip`, `mdtp`, `lksecapp`/`bak`, `cmnlib`/`bak`, `cmnlib64`/`bak`, `keymaster`/`bak`, `dpo`, `logdump`, `resource`, `userdata`).
- Root after the grow: MBR partition 2 inside `system` = 14000128 sectors, ext4 1750016 blocks = **6.68 GiB**.

## Findings

- **Live `persist` is not byte-identical to the backup image.** On the device: `19c5dd29...d6ce2`; `backup-20261029/partitions/persist.img`: `06dca40a...a1`. The backup was read while Android had `/persist` mounted (`needs journal recovery`); Android's clean unmount afterwards (last write 09:41 vs 09:00 epoch-time) changed 232 bytes in the superblock, group descriptors and journal. Both images, once checked with `e2fsck`, have identical file contents (`debugfs rdump` + `diff -r`: 11 files, `sensors/`, `speccfg/`, `rfs/`, no differences). So the procedure copies the **live** partition and checks it against the live hash. A copy is in `flash-work/stage-b/persist-live-20261030.img`. Checking against `SHA256SUMS.device` would fail for `persist`. The four small ones (`syscfg`, `mcfg`, `apdp`, `msadp`) match the backup exactly.
- **The GPT on the device is byte-identical to `gpt_primary.bin` / `gpt_backup.bin`** (read back over adb). Stage A did not touch it.
- **sfdisk does not reproduce Lenovo's GPT bytes.** From `stock_layout.sfdisk` it writes the same primary header and entries, but it puts a protective MBR of disk-size-1 instead of 0xFFFFFFFF (3 bytes), and the backup entry array right below the backup header (15269874) instead of at last-lba + 1 (15269855). Both forms are valid, and rickx's working table is the sfdisk form. Even so, the procedure writes blobs in Lenovo's form. `make-gpt-blobs.py --selftest` shows the construction reproduces the stock backup exactly from the stock primary. Rollback writes the original files.
- **eMMC write protection:** `EXT_CSD USER_WP = 0x10` (permanent WP disabled, no power-on WP), `BOOT_WP = 0`. Nothing stops a GPT write from Linux. Erase group 512 KiB, WP group 8 MiB.
- **Dropped partitions and the boot chain:** rickx's dump of a working unit (`devices/storage-emmc/evidence/ubuntu-rickx-gpt-sfdisk-20260528.txt`, 25 entries) shows aboot + lk2nd boot without any of the 22 we drop. The remaining uncertainty is the same unit-to-unit aboot version question as before. A failed boot is recovered with the two stock blobs over EDL.
- **`tsv-growroot` already ran on the first boot** (`/var/lib/tsv/growroot.done`, "Nothing to do"), so it will not run on its own after repartitioning. `stage-b.sh grow` removes the marker after the new table has booted once. The loop device is created at boot from the kernel's view of p24, so the reboot is also what gives `/dev/loop0` its new size.
- The device clock is wrong (2026-10-19, no NTP without Wi-Fi). Irrelevant to the partition work. It matters for pacman: signatures made "in the future" are rejected, so time must be set before installing Omarchy.

## Rehearsal (laptop, `rehearse.sh`, 26 s)

On a sparse 7818182656-byte image with the stock GPT copies, the Arch system image in p24, the live `persist` and the backed-up small partitions at their stock places, and random data where the tail goes:

1. precheck: stock GPT recognised byte for byte; all five tail hashes OK.
2. copy-tail: all five copied and read back OK.
3. write-gpt: both copies byte-identical to the blobs; `sfdisk -d` equals `layout.sfdisk`; `sfdisk --verify` clean.
4. rollback-gpt: stock again, byte-identical to `backup-20261029`; precheck passes; new GPT written again.
5. Interrupted write (backup copy new, primary stock): the disk still reads as the stock table.
6. After "reboot": 29 partitions; `persist` at 15187968 byte-identical to the live copy (`debugfs` lists `sensors`, `speccfg`, `data`, `bms`, `rfs`); the first 1.5 GiB of p24 unchanged (sha256 `6dfa3835...`).
7. Growroot, with the exact `sfdisk ',+' -N 2` that `tsv-growroot` runs: MBR p2 becomes 264192 + 14000128; `e2fsck` clean before; `resize2fs` gives 1750016 blocks (6.68 GiB); `e2fsck` clean after. The rehearsal resizes offline on a copy, while the device resizes online; the online path needs no new GDT blocks (11 to 54 groups, 64 per descriptor block).

Not rehearsable without root on the laptop: the kernel/udev behaviour on a real block device. The reasoning is in RUNBOOK.md: no re-read, `BLKRRPART` fails `EBUSY` while p24 is open, and the loop device keeps p24's old size until the reboot.

## Omarchy plan

### Source

- **`pkgs.omarchy.org/stable/aarch64` now exists** (183 packages; `omarchy` 4.0.6, `omarchy-settings`, `hyprland` 0.56.2, `quickshell`, `walker`, `mise-bin`, `yay`, `ufw-docker`, all the first-party apps; packages have detached `.sig`, the database is unsigned). omarchy-arm 579f15c6 still says it 404s and **removes `[omarchy]`** from `pacman.conf` (`install/arm/pacman.sh`).
- Replaying `install.sh`'s package-plan logic offline against the ALARM databases (`work/plan-replay.txt`): with today's device `pacman.conf`, 124 come from the repos, 2 are AUR-required, 8 AUR-optional and 13 unavailable. With `[omarchy]` aarch64 added, 146 come from the repos and only `dotnet-runtime` is unavailable (it is shipped as `dotnet-runtime-bin`). `xdg-terminal-exec` is now in ALARM `extra`.
- **`[omarchy]`'s `hyprland` 0.56.2 cannot be installed on ALARM.** It depends on soname provides (`libaquamarine.so=14-64` and others) that Arch Linux ARM packages do not declare at all (0 `.so` provides in core/extra/alarm). ALARM `extra` has **Hyprland 0.57.0**, so that is what gets installed (`[omarchy]` is placed after ALARM's repos). The fork was validated on 0.56.1 with Omarchy's Lua config. A 0.57 config break is the main software risk; check `hyprctl configerrors` first.
- Plan: run omarchy-arm `install.sh --skip-packages` after installing our own package list, with `omarchy-arm-thinksmart.patch`:
  1. `enable-services.sh`: enable only units that exist. Without this, a trimmed set (no cups, docker or kernel-modules-hook) aborts `omarchy-apply-system`, because the leaf runs under `bash -e`.
  2. `docker.sh`: skip the docker group when docker is not installed (`usermod -aG docker` would abort the same way).
  3. `pacman.sh`: keep `[omarchy]` when it points at `$arch`/aarch64.
  4. `settings.sh`: do not replace an existing `/etc/plymouth/plymouthd.conf`. Omarchy's is `Theme=omarchy` only and would drop `DeviceScale=1`, `DeviceTimeout=8` and `ShowDelay=0`; `plymouth-set-default-theme -R aiand` only rewrites `Theme=`.
  5. `hardware/arm/vulkan.sh`: on `generic-aarch64` (our detection result) it installs `vulkan-virtio` and `vulkan-swrast`. With an msm GPU, install nothing: there is no Vulkan for a5xx, and with lavapipe present GTK4 would choose Vulkan and render on the CPU.

### Size

Computed with `omarchy-size.py` against the ALARM aarch64 databases (2026-10-29/30) and `[omarchy]` aarch64, minus the 200 packages already on the device:

| Set | New packages | Installed | Download | Fits 6.68 GiB root? |
| --- | --- | --- | --- | --- |
| Full omarchy-arm base + extras (`work/size-full.txt`) | 205 | 4.86 GiB | 1.57 GiB | no: 0.94 + 4.86 + 1.57 cache = 7.4 GiB at peak |
| **Tablet** (`omarchy/tablet.packages`, `work/size-tablet.txt`) | 112 | **1.44 GiB** | 0.42 GiB | **yes**: about 2.5 GiB used afterwards (0.94 now + 1.44 + 77 MiB Omarchy tree + user data), 3 GiB at peak with the package cache, about 3.9 GiB free |
| Tablet without Chromium | | 1.00 GiB | | |

Biggest in the tablet set: chromium 448 MiB, qt6-declarative 149, noto-fonts 107, qt6-base 73, hyprland 65, yaru-icon-theme 63, gtk4 57.

Left out (all in `omarchy/tablet.drop` with reasons): `qemu-user-static-binfmt` (550 MiB), `libreoffice-fresh` (466), `obsidian` (432), `aether` (178, webkit2gtk), `obs-studio` (166), `mise-bin` (128; Omarchy gates every mise step on the command existing, so the AI CLI wrappers are simply not set up), clang/llvm (203), docker and friends (231), `kdenlive` (96), `localsend`, `cliamp`, `herdr`, `pinta`/.NET, `moonlight-qt`, `gpu-screen-recorder`, the dev libraries (`mariadb-libs`, `postgresql-libs`, ruby, lua51/luarocks, tree-sitter-cli, poetry-core), `omarchy-nvim` (neovim stays), printing (cups x4, system-config-printer), `ddcutil`, `bolt`, `asdcontrol`, `kernel-modules-hook`, `gvfs-{mtp,nfs,smb}`, fcitx5 x3 (conflicts with the on-screen keyboard), tesseract. `noto-fonts-cjk` (299 MiB) is replaced by `adobe-source-han-sans-jp-fonts` (32 MiB).

Added: `squeekboard` (on-screen keyboard), `iio-sensor-proxy` (accelerometer and light sensor), `adobe-source-han-sans-jp-fonts`.

**Chromium stays**: it is Omarchy's browser and web-app engine, and it fits. It is the first thing to drop if RAM proves too tight (448 MiB of disk saved).

### RAM (2 GB, 1941 MiB visible, 293 MiB used today)

Estimated, not measured: Hyprland + Quickshell bar + PipeWire/WirePlumber + portals come to roughly 0.4-0.5 GiB on top of today's base. Chromium with one or two tabs adds 0.4-0.7 GiB. That fits without swap, with little margin. Omarchy relies on zram (`zram-size = ram`, zstd) and systemd-oomd, and **the kernel has neither**:

- **Kernel config request (integrator):** `CONFIG_ZRAM=m` (pulls in `ZSMALLOC`), `CONFIG_ZRAM_BACKEND_ZSTD=y` (`CRYPTO_ZSTD=m` is already set), and `CONFIG_PSI=y`, which systemd-oomd needs. Without zram, Omarchy's `vm.swappiness=150` has nothing to act on. Without PSI, the oomd unit Omarchy enables does nothing. `CONFIG_ZSWAP` stays off (Omarchy turns it off anyway).

### Touch and panel (files in `omarchy/home/.config/`)

- `hypr/monitors.lua`: `DSI-1`, 800x1280@60, **scale 1.25** (640x1024 logical, both sides whole numbers), no transform (native portrait, camera top left), `GDK_SCALE=1`, `GSK_RENDERER=ngl`. Confirm the connector name with `hyprctl monitors all`.
- `hypr/input.lua`: touchscreen mapped to `DSI-1`, transform 0 (change if touches land rotated).
- `hypr/looknfeel.lua`: animations, blur and shadows off (as the fork does for the Pi); small gaps.
- `hypr/autostart.lua`: `squeekboard`, which shows itself when a text field takes focus (input-method-v2 / text-input-v3). Chromium gets `--enable-wayland-ime --wayland-text-input-version=3 --touch-events=enabled`.
- `omarchy/shell.json` idle: screensaver and lock pushed out to one year (`0` means "immediately" in `IdleModel.js`). A password lock screen on a device with no keyboard locks the owner out at the panel, because session-lock hides the on-screen keyboard. Screen-off on idle is a follow-up (hypridle + `dpms`). Check first whether the FT8201 (TDDI) still reports touches with the panel off; if not, wake on volume keys/proximity per GOAL.
- Gestures: Hyprland's `hl.gesture` is for touchpads. Edge swipes on the touchscreen need `lisgd` (AUR, small C program) or the `hyprgrass` plugin (hyprpm, needs a build toolchain on the device; not worth it). Proposed: build `lisgd` once in the ALARM chroot on the laptop and ship it in the overlay. Bindings: left/right edge = workspace, bottom edge up = keyboard, top edge down = Omarchy menu. Not done yet.
- Auto-rotation (GOAL accelerometer item): `iio-sensor-proxy` is in the set; a small `monitor-sensor` to `hyprctl` rotation hook is a follow-up, coordinated with `idle-rotate`.
- Bar: Omarchy's top bar at 640 logical px will be crowded; trim modules (weather, keyboard layout) on the device.

### Base-image requirements kept (`install-omarchy.sh fixup`)

- ai& Plymouth: our `plymouthd.conf` stays (patch item 4; restored if replaced), then `plymouth-set-default-theme -R aiand`; `lsinitcpio` must show `hooks/tsv-subpart` and `themes/aiand`.
- `/etc/mkinitcpio.conf.d/zz-tsv-hooks.conf` must still be the last drop-in. The fork skips `mkinitcpio.conf.d/` anyway, and the script stops if it is not last.
- USB gadget, DHCP, adbd, sshd: checked still enabled. Omarchy's `ufw` default-deny would block the laptop's DHCP request on `usb0` (the fork only opens port 22), so `ufw allow in on usb0` is added. Omarchy disabling `systemd-networkd` is harmless: `usb0` is "unmanaged" and set up by `tsv-usb-gadget`, and the `.link` file is applied by udev.
- Idle screen to display manager: enabling `sddm.service` creates `/etc/systemd/system/display-manager.service`, and from the next boot `tsv-idle-screen` is skipped by its `ConditionPathExists=!` and ordered before SDDM. SDDM gets autologin (`etc/sddm.conf.d/20-tsv-autologin.conf`: `jethac`, session `omarchy`, `Relogin=true`), since there is no keyboard for a greeter. Reboot rather than starting SDDM live.

### Device dry run

Not run: the device has no internet (`ping archlinux.org`: name resolution fails; `wlan0` disconnected). `install-omarchy.sh dry-run` needs the omarchy-arm checkout pushed and, for a meaningful plan, a fresh `pacman -Sy` with `[omarchy]` added, so it waits for Wi-Fi as agreed. It changes nothing.

## For GOAL.md (integrator)

"Left out for size or RAM" list: the `tablet.drop` table above, in short form. "Restoring stock ... tried at least once": the runbook's optional drill at step 5 (rollback-gpt, byte-identical, then the new table again) covers the partition table, and copy-tail plus postboot covers one partition (`persist`).

## Approval request (for the integrator to relay)

> **Stage B: repartition the tablet's eMMC.** I'd like approval to rewrite the partition table from the running system, as in `streams/stage-b/RUNBOOK.md`.
>
> **What gets written:** (1) 39 MiB at the end of the old Android `userdata` area, holding copies of `persist`, `syscfg`, `mcfg`, `apdp` and `msadp`, each checked by SHA-256 after writing; (2) the two GPT copies, 34 + 33 sectors, as pre-built files; (3) after one test reboot, root grows from 1.4 GiB to 6.7 GiB. Partitions 1-23 (bootloaders, modem, `modemst*`, `fsg`, `devinfo`, `boot` with lk2nd) and the running system are not touched. 22 Android partitions (`vendor`, `userdata`, `keymaster`, `cmnlib*`, `misc`, `resource` and others) are dropped; all except `userdata` are in the 2026-10-29 backup.
>
> **What is at risk:** the first boot on the new table. If aboot or lk2nd turns out to need a dropped partition, the tablet does not boot and has to be recovered over EDL by writing the two stock GPT files back. That returns it exactly to today's state; nothing else needs restoring at that point. The same layout family has booted on this model before (rickx's Ubuntu port). `persist` (Wi-Fi/BT MACs, sensor calibration) is copied, not moved: the original stays where it is until the final step, and there are two copies on the laptop.
>
> **Point of no return:** the last step (growing root). Before it, going back is one command from the running system (`stage-b.sh rollback-gpt`, which I've rehearsed), or two EDL writes if it doesn't boot. After it, going back to stock means reflashing partitions from the backup over EDL.
>
> **How long:** about 5 minutes hands-on, about 15 seconds of actual writes, one reboot (about 40 s). The device is out of use for the duration (under the device lock).

## Open items

- Kernel config (integrator): `CONFIG_ZRAM=m`, `CONFIG_ZRAM_BACKEND_ZSTD=y`, `CONFIG_PSI=y`. Needed before Omarchy is usable for long on 2 GB.
- Hyprland 0.57.0 (ALARM) against Omarchy 4.0's Lua config, validated by the fork on 0.56.1: check `hyprctl configerrors` right after the first session.
- `lisgd` build and gesture bindings; auto-rotation hook; idle screen-off with touch or volume-key wake.
- `[omarchy]` uses `SigLevel = Optional TrustAll` as in Omarchy's own `pacman.conf`. Tighten to `Required` once `omarchy-keyring` is populated and a package installs cleanly with it.
- Whether `resource` (dropped, 356 MiB) is wanted by the ADSP later (storage analysis open question). It is in the backup (`resource.img.zst`), and its old extent is overwritten by the grow.
