# Arch Linux ARM image for the ThinkSmart View (milestone 5)

An aarch64 Arch Linux ARM system for the Lenovo ThinkSmart View CD-18781Y (APQ8053),
with the msm8953-mainline 7.3 kernel from `../kernel/build-7.3`, built rootless on the x86_64
laptop. Nothing in this directory has been on the tablet yet.

| | |
| --- | --- |
| Image | `out/thinksmart-alarm-system.img`: raw image for the GPT `system` partition, sparse, 1536 MiB |
| Checksum | `out/thinksmart-alarm-system.img.sha256` |
| Partition listing | `out/thinksmart-alarm-system.partitions.txt` |
| Firmware manifest | `out/firmware-manifest.tsv` |
| Rebuild | `scripts/build-image.sh` |
| Wi-Fi credentials | `scripts/inject-wifi.sh` |

## Layout

The image goes into the GPT `system` partition (p24) and carries its own MBR, the same
scheme as the Ubuntu port and postmarketOS:

| MBR part | Start (sector) | Size | FS | Label | Mounted at | Contents |
| --- | --- | --- | --- | --- | --- | --- |
| 1 (boot flag) | 2048 | 128 MiB | ext2 (`filetype,sparse_super,large_file` only, 4 KiB blocks) | `tsv-boot` | `/boot` | `extlinux/extlinux.conf`, `Image.gz`, `initramfs-tsv.img`, `dtbs/qcom/apq8053-lenovo-cd-18781y.dtb`, `config-7.3.0-g755ffc44d5d8` |
| 2 | 264192 | rest (1.37 GiB in the image) | ext4 | `tsv-root` | `/` | Arch Linux ARM |

- **Size.** The image is 1536 MiB, exactly the size of the stock `system` partition
  (3145728 sectors), so it can be written before or after repartitioning. On first boot
  `tsv-growroot.service` extends MBR partition 2 to the end of whatever GPT partition holds the
  image and grows ext4 online. Under the rickx layout (`system` = 14280671 sectors, 6.81 GiB),
  root ends up at about 6.68 GiB. Today about 965 MiB of root is used.
- **How Linux finds root.** Linux does not scan a partition table nested inside a partition.
  The initramfs hook `tsv-subpart` (`scripts/overlay/etc/initcpio/hooks/tsv-subpart`) runs
  `losetup -f -P --direct-io=on` on `PARTLABEL=system`. That makes the two filesystems appear
  as `/dev/loop0p1` and `/dev/loop0p2`, and `root=LABEL=tsv-root` resolves. Direct I/O avoids
  caching the same blocks twice on a 2 GB machine. To map a different partition, use
  `tsv_subpart=<spec>`; `tsv_subpart=none` turns the hook off.
- **Kernel command line** (in `extlinux.conf`):
  `root=LABEL=tsv-root rw tsv_subpart=PARTLABEL=system console=tty0 quiet splash loglevel=4`
  (see [Boot splash and idle screen](#boot-splash-and-idle-screen) for why `quiet splash`)

### Where lk2nd looks for `extlinux.conf`

**`msm8953-mainline/lk2nd` has no extlinux support at all.** Its README says "This project is
not maintained" and points to `msm8916-mainline/lk2nd`, and its tree has no `extlinux` code and
no CD-18781Y device. The lk2nd that supports this device and boots extlinux is
**`msm8916-mainline/lk2nd`**, which also covers MSM8953 (`lk2nd-msm8953` target). The device
DTS is `lk2nd/device/dts/msm8953/apq8053-lenovo-cd-18781y.dts` (`lk2nd,dtb-files =
"apq8053-lenovo-cd-18781y"`; build with `SIGN_BOOTIMG=1 LK2ND_QCDTBS=""`; flash with EDL).
Commits read: msm8916-mainline `fd380ac637d1af38598e3f3c5321d4c962b96315` (2026-10-20) and
msm8953-mainline `97e15454b9aac5b48ba8bc106db66035c14106c9`. Both are cloned under
`downloads/`.

This is what that lk2nd does:

1. **Which block devices.** `lk2nd/hw/bdev/wrapper.c` publishes every GPT partition as
   `wrp0pN`, then calls `partition_publish()` on each one (`lib/partition/partition.c`). That
   function looks for an **MBR** signature (`0x55AA`) at sector 0 of the partition. It does not
   look for GPT. If the signature is there, the MBR entries become sub-devices `wrp0pNpM`, and
   the parent stops being a leaf (`lib/bio/subdev.c`).
2. **Which of those it tries.** `lk2nd_scan_devices()` in `lk2nd/boot/boot.c` goes through
   every **leaf** block device in list order and skips those smaller than
   `LK2ND_BOOT_MIN_SIZE` (16 MiB), unless the GPT label starts with `boot`. For each one left it
   calls `fs_mount(..., "ext2", ...)`. Our `system` partition has an MBR, so only its two
   sub-partitions are leaves. Both are at least 16 MiB.
3. **Which filesystem.** lk2nd only has **ext2** (`lib/fs/rules.mk` registers only
   `lib/fs/ext2`). That is LK's ext2 driver. It reads files through direct and indirect block
   maps, with **no extents**. It rejects any `ro_compat` feature other than `sparse_super` and
   `large_file` (`lib/fs/ext2/ext2.c`, `ext2_mount`). It reads 32-byte group descriptors, so
   **no 64bit**. An ordinary ext4 filesystem (extents, `metadata_csum`, `huge_file`,
   `dir_nlink`, `extra_isize`) cannot be read. The boot partition is therefore built with
   `mke2fs -t ext2 -O none,filetype,sparse_super,large_file -b 4096`.
   `scripts/inspect-image.sh` checks that every file lk2nd loads has inode flags `0x0`, which
   means no extents.
4. **Which path.** `lk2nd_try_extlinux()` in `lk2nd/boot/extlinux.c` opens
   **`/extlinux/extlinux.conf`** at the root of that filesystem. The first filesystem where the
   file parses and every referenced file exists gets booted. If none does, lk2nd says
   "Bootable file system not found. Reverting to android boot." Paths inside the file are
   absolute to that filesystem root; a relative path gets `/extlinux/` prefixed
   (`normalize_path`).
5. **Keywords.** `label`, `default`, `linux`/`kernel`, `initrd`, `append`, `fdt`/`devicetree`,
   `fdtdir`/`devicetreedir` (tries `<dir>/qcom/<dtb-files>.dtb`, then `<dir>/qcom-*.dtb`, then
   `<dir>/<name>.dtb`) and `fdtoverlays`. Every other keyword is ignored. A gzip kernel is
   decompressed. The `fdt` or `fdtdir` line is mandatory.
6. **Memory limit** (`choose_addrs`, `LK2ND_BOOT_MEM_SIZE` = 50 MiB from `0x80000000` on
   msm8953). The initramfs sits at the top of that 50 MiB, with a 2 MiB DTB area below it, and
   the decompressed kernel must fit underneath. The kernel `Image` is 23.3 MiB (`image_size`
   23.3 MiB), so the initramfs must stay under about 24 MiB. It is currently 13.4 MiB (zstd -19), with
   Plymouth; it was 10.9 MiB without.

## What is installed

- **Base.** Arch Linux ARM aarch64 generic tarball (`ArchLinuxARM-aarch64-latest.tar.gz`,
  2026-08-05). The md5 is checked, and the GPG signature is checked against key
  `68B3537F39A313B3E574D06777193F152BDBE6A6` (Arch Linux ARM Build System). Packages are then
  upgraded with `pacman -Syu`.
- **Removed:** `linux-aarch64`, all `linux-firmware*` (about 970 MiB, none of it used here),
  `netctl` and `dhcpcd`.
- **Added:** `networkmanager` (pulls in `wpa_supplicant`), `dnsmasq`, `sudo`, `wireless-regdb`,
  `iw`, `plymouth` (boot splash; 28 packages with its dependencies). `mkinitcpio` is kept. That
  makes 200 packages in total, and no desktop.
- **Kernel.** `7.3.0-g755ffc44d5d8`, copied from `../kernel/build-7.3` without rebuilding
  (`Image.gz` and DTB). The 686 modules were installed with `make ... INSTALL_MOD_STRIP=1
  modules_install` into `/usr/lib/modules`. Stripped, they take 38 MiB instead of 508 MiB.
- **Initramfs** (mkinitcpio, `HOOKS=(base udev modconf plymouth tsv-subpart fsck)` in
  `/etc/mkinitcpio.conf.d/zz-tsv-hooks.conf`, no `autodetect` because it is built in a chroot):
  - Modules: `msm`, `panel-lenovo-cd-18781y-ft8201`, `panel-lenovo-cd-18781y-hx83100a`,
    `qcom-wled`, plus their dependencies (18 modules in all).
  - Firmware: `a530_pm4.fw`, `a530_pfp.fw` and `a506_zap.*`.
  - Tools: util-linux `losetup` and `blkid`, `e2fsck`.
  - Plymouth with the `aiand` theme (see [Boot splash and idle screen](#boot-splash-and-idle-screen)).
  - There is a preset at `/etc/mkinitcpio.d/tsv.preset`, so `mkinitcpio -P` on the device
    regenerates `/boot/initramfs-tsv.img`.
- **System settings.** Hostname `thinksmart`, timezone `Asia/Tokyo`, `LANG=en_US.UTF-8`
  (generated), keymap `us`. `cfg80211 ieee80211_regdom=JP`. `systemd-resolved` and
  `systemd-timesyncd` are enabled.
- **Users:**
  - The stock `alarm` account is deleted.
  - root gets the password field `!*`, so it has no password and cannot log in over ssh
    (`PermitRootLogin no`).
  - `jethac` is uid 1000, in group `wheel`, which has `%wheel ALL=(ALL:ALL) ALL` in
    `/etc/sudoers.d/10-wheel`.
  - `~jethac/.ssh/authorized_keys` is this laptop's `id_ed25519_stadia_testbed.pub`, mode 0600.
- **Password.** It comes from `TSV_JETHAC_PASSWORD` at build time. Only a SHA-512 crypt hash
  (`openssl passwd -6 -stdin`) reaches the image, and the plaintext is not written to disk or
  logs. **This build ran without it, so `jethac` has `*` as its password: no password login,
  key only, and `sudo` will not work until a password is set.** The `*` is deliberate, not
  `!`: with `!` sshd treats the account as locked even for key logins when PAM is off.
- **adbd.** `/opt/adbd` plus `tsv-adbd.service`: adb over USB with key authentication and a root
  shell. See [adb](#adb).
- **sshd.** Enabled. `/etc/ssh/sshd_config.d/10-thinksmart.conf` sets
  `PasswordAuthentication yes`, `PubkeyAuthentication yes`, `PermitRootLogin no` and
  `KbdInteractiveAuthentication no`. Host keys are generated on first boot
  (`sshdgenkeys.service`), so none are shipped.
- **First boot:**
  - `machine-id` is `uninitialized`.
  - The pacman keyring is not shipped; `tsv-pacman-keyring.service` runs `pacman-key --init`
    and `--populate archlinuxarm`.
  - `tsv-growroot.service` grows root.
- **Network stack.** NetworkManager handles Wi-Fi, rather than iwd plus systemd-networkd.
  Omarchy uses NetworkManager: its installer (`install/hardware/network.sh`) disables iwd and
  every `systemd-networkd` unit. Anything built on networkd would be switched off when Omarchy
  goes on in milestone 7. `NetworkManager-wait-online` is masked, as Omarchy does.

## Firmware

All firmware comes from this unit's backup (`../backup-20261029/partitions`). The SHA-256 of
each partition image is checked against `SHA256SUMS.device` first. Nothing is downloaded and
nothing comes from another device. The images are read without mounting: `scripts/fatextract.py`
for the FAT16 `modem` image, `debugfs` for the ext4 `vendor` image.
`scripts/extract-firmware.sh` does the work and `out/firmware-manifest.tsv` is the full table.
**Keep these blobs out of public git.**

| Destination (`/lib/firmware/…`) | Source | SHA-256 | Requested by |
| --- | --- | --- | --- |
| `qcom/msm8953/lenovo/cd-18781y/adsp.mdt` | modem `/firmware/image/adsp.mdt` | `5e0c0399…ff1738` | `qcom_q6v5_pas`: `qcom,msm8953-adsp-pil` uses `msm8996_adsp_resource`, `firmware_name = "adsp.mdt"`. The DTS sets no `firmware-name` on `&lpass`, so the driver loads `/lib/firmware/adsp.mdt`, a symlink to this file. |
| `qcom/msm8953/lenovo/cd-18781y/adsp.b00`…`b14` | modem `/firmware/image/adsp.b00`…`b14` | see manifest | mdt loader, segments next to `adsp.mdt`. Symlinks `adsp.bNN` point here. |
| `qcom/msm8953/lenovo/cd-18781y/venus.mdt` | modem `/firmware/image/venus.mdt` | `24210f57…e458c6` | `venus/core.c` `msm8953_res.fwname = "venus.mdt"`, with no `firmware-name` in the DTS. Symlink `/lib/firmware/venus.mdt` points here. |
| `qcom/msm8953/lenovo/cd-18781y/venus.b00`…`b04` | modem `/firmware/image/venus.b00`…`b04` | see manifest | mdt segments. Symlinks `venus.bNN` point here. |
| `qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt` | vendor `/vendor/firmware/a506_zap.mdt` | `5a735406…154131` | `&gpu_zap_shader firmware-name = "qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt"` in the device DTS |
| `qcom/msm8953/lenovo/cd-18781y/a506_zap.b00` | vendor `/vendor/firmware/a506_zap.b00` | `f68aeb6f…541ced` | zap segment |
| `qcom/msm8953/lenovo/cd-18781y/a506_zap.b01` | vendor `/vendor/firmware/a506_zap.b01` | `70e08e5c…d328aa` | zap segment |
| `qcom/msm8953/lenovo/cd-18781y/a506_zap.b02` | vendor `/vendor/firmware/a506_zap.b02` | `fe8dead2…1930fd` | zap segment |
| `qcom/a530_pm4.fw` | vendor `/vendor/firmware/a530_pm4.fw` | `6419f359…cb1d3f` | `a5xx_catalog.c`, a506 `ADRENO_FW_PM4`, requested as `qcom/<name>` |
| `qcom/a530_pfp.fw` | vendor `/vendor/firmware/a530_pfp.fw` | `ed2c860a…a3b00e` | a506 `ADRENO_FW_PFP` |
| `ath10k/QCA9379/hw1.0/firmware-sdio-5.bin` | modem `/firmware/image/qwlan30.bin` (`2914b3a5…322ceb`, identical to `athwlan.bin`) and `otp30.bin` (`c6d4e1eb…e3066`), packed | `148b1db2…58aafc` | `ath10k_sdio`, QCA9379 hw1.0 SDIO entry (`QCA9379_HW_1_0_FW_DIR`), `firmware-sdio-<api>.bin`, API 2 to 6 |
| `ath10k/QCA9379/hw1.0/board.bin` | modem `/firmware/image/bdwlan30.bin` | `65767cca…bda7d4` | ath10k board API 1. This is the same board file Felix Kaechele used upstream (same SHA-256). |
| `qca/rampatch_00150100.bin` | modem `/firmware/image/btfwnpla.tlv` | `0fa3169e…0e564e` | `btqca`: compatible `qcom,qca6174-bt` makes this `QCA_ROME`, which asks for `qca/rampatch_%08x.bin`. 00150100 is QCA9379-3 (Kaechele, "Bluetooth: hci_qca: add compatible for QCA9379", 2024-08). |
| `qca/nvm_00150100.bin` | modem `/firmware/image/btnvnpla.bin` | `4e36326d…b06c19e` | `btqca` `qca/nvm_%08x.bin` |

Notes:

- **Why the symlinks.** The real files sit in the postmarketOS-style per-device directory, and
  the driver default names are relative symlinks. If the DTS later gains
  `firmware-name = "qcom/msm8953/lenovo/cd-18781y/…"`, nothing has to move. pmaports has no
  `device-` or `firmware-lenovo-cd-18781y` package at commit
  `e28b230e5600e35403f63c14705df200ed052f06`. Only `device-qcom-msm8953` mentions the board,
  in a hwdb file. The paths therefore come from the 7.3 DTS and driver source.
- **The Wi-Fi firmware container.** Stock ships the raw image, but ath10k needs the
  `ath10k-fwencoder` container (API 2 or later). `scripts/ath10k-fwpack.py` builds it from the
  enums in `ath10k/hw.h` and `core.h`.
  - Version string: `WLAN.NPL.1.6-00163-QCANPLSWPZ-1`, from `verinfo/ver_info.txt`.
  - WMI and HTT op version: `tlv`.
  - OTP image included.
  - Features: `wowlan,ignore-otp,mfp`. That is the set the working 6.19 port logged. Upstream
    tests used `ignore-otp` alone, and linux-firmware's QCA9377 SDIO file has the same layout
    with `ignore-otp` alone.
  - The timestamp is fixed, so the output is reproducible.
- **Zap shader source.** The modem partition also carries a zap shader, `image/gfx.*`. Its
  `.mdt` and `.b01` (hash and signature) segments differ from `/vendor/firmware/a506_zap.*`,
  while `.b00` and `.b02` are identical. Stock Android loads the vendor copy, so the image uses
  that one. If zap authentication fails on mainline, the `gfx.*` set is the other candidate.
- **Not extracted:**
  - WCNSS (no WCNSS on this board; the DTS deletes the node).
  - Modem and MBA (no modem).
  - `cpe_9335`, `cmnlib*`, widevine and other TrustZone apps.
  - `dsp.img`, which holds ADSP userspace libraries for FastRPC, not PIL firmware.
  - `persist`, which holds sensor calibration and the BT and Wi-Fi MAC under `bluetooth/`. It
    stays on its own partition and is not needed to boot.
  - `rmtfs`: nothing needs it without a modem.

## USB networking

The Linux side is `tsv-usb-gadget.service` running `/usr/local/sbin/tsv-usb-gadget run`. It is
enabled in `sysinit.target`, is independent of NetworkManager and Wi-Fi, and does not hold up
boot (`Type=simple`). It keeps running after the bind to supervise it (see [adb](#adb)):

- **Controller.** It waits up to 120 s for a UDC to appear in `/sys/class/udc`. That is the
  DWC3 at `7000000`; `msm8953.dtsi` gives it `usb-role-switch` with
  `role-switch-default-mode = "peripheral"`.
- **Gadget.** It builds configfs gadget `tsv` as VID:PID `1d6b:0104`, with one configuration
  holding **NCM** (`ncm.usb0`) and **ACM** (`acm.GS0`), plus **adb** (`ffs.adb`, linked last and
  only while adbd is ready). The device class is `0xEF/2/1` (IAD), marked self-powered. The MAC addresses (locally administered) and the USB serial number are
  derived from the SoC serial number, falling back to `machine-id`, so they stay the same
  across reboots.
- **Address.** It binds the gadget, then sets `172.16.42.1/24` on `usb0` with `ip`. The address
  survives cable unplug and replug.
- **Interface names.** NetworkManager is told to leave `usb*` alone
  (`/etc/NetworkManager/conf.d/10-thinksmart.conf`). The udev `.link` file
  `/etc/systemd/network/10-tsv-usb-gadget.link` stops udev renaming `usb0`. It is applied by
  udev, so it still works with networkd disabled.
- **DHCP.** `tsv-usb-dhcp.service` runs a private `dnsmasq`
  (`/etc/tsv/usb-dnsmasq.conf`). It serves DHCP only (`port=0`) on `usb0`, with
  `bind-dynamic`, a range of `172.16.42.10`–`.50` and 1 h leases. It sends **no router and no
  DNS options**, so the laptop keeps its own default route. The packaged `dnsmasq.service` is
  left free.
- **Serial console.** The script starts `serial-getty@ttyGS0.service`, a login on the ACM port.
- **No RNDIS.** The laptop runs Linux and `cdc_ncm` works there out of the box. Adding RNDIS
  would add a second interface and subnet, or a bridge, for no gain on this host.

From the laptop:

```sh
# The tablet appears as a cdc_ncm interface (e.g. enp0s20f0u1); NetworkManager on the
# laptop picks up a 172.16.42.x lease automatically. Then:
ssh -i ~/.ssh/id_ed25519_stadia_testbed jethac@172.16.42.1
# If DHCP does not come up, give the interface an address by hand:
#   sudo ip addr add 172.16.42.2/24 dev <iface>
# Serial fallback (ACM):
#   screen /dev/ttyACM0 115200      # login prompt; needs a password set for jethac
```

## adb

`adb shell`, `adb push`/`pull` and `adb reboot` work over the same USB cable, as a third
function of the gadget. adbd runs as **root** and `adb shell` is a root shell. That is a
deliberate choice: the point is to administer the box. Anyone holding the laptop's
`~/.android/adbkey` gets root on the tablet, so that key matters as much as the SSH key plus
`jethac`'s password.
Upstream adbd also sets `oom_score_adj` to -950 on every process it starts. Something
memory-hungry started from `adb shell` therefore makes the OOM killer pick other processes
first. Run large jobs over SSH, or with `choom -n 0 -- cmd`.

### Which adbd, and why

| Option | Verdict |
| --- | --- |
| Debian's `adbd` binary (34.0.5-13, forky) | **Rejected: authentication is off.** Debian carries `adbd-don-t-require-authorization-on-Linux.patch`, which sets `auth_required = false` unconditionally on Linux. Without FunctionFS it also listens on `tcp:5555` and `vsock:5555`. |
| **Debian's source, rebuilt without that patch** | **Chosen.** Same maintained source package (`android-platform-tools` 34.0.5-13; Debian also has 35.0.2 in experimental), the rest of Debian's patch series, and four small patches of ours. |
| Build statically | Not done. Debian ships `libbase`, `libcutils`, `liblog` and BoringSSL only as shared libraries, so a static adbd means building all of them from source as well. The shared libraries are private to `/opt/adbd/lib`, which removes the collision risk that a static build would have avoided. |
| postmarketOS | pmaports (`e28b230e`) has no adbd package; no path in the tree matches `adbd`. postmarketOS gives USB access through its own gadget scripts with telnet and SSH. |
| Older Linux adbd forks (Buildroot's `android-tools` 4.2.2, meta-oe 5.1.1) | Rejected. They are built from 2013 to 2015 AOSP code and nobody maintains them. |

Authentication works without the Android framework. Modern adbd delegates key storage to
`libadbd_auth` (`frameworks/native/libs/adbd_auth`, compiled into adbd here). That library reads
the authorized keys from a file itself. The prompt for an unknown key would go to
`system_server` over the `adbd` control socket. On Linux that socket does not exist
("socket unavailable, disabling user prompts"), so an unknown key is never authorized and the
host stays `unauthorized`. Nothing is accepted without a listed key.

### What is built and installed

`scripts/fetch-adbd.sh` downloads into `downloads/adbd-debian/`, and checks everything on
every run, offline once it is downloaded:

- **Trust anchors.** The Debian archive keys 12/bookworm `B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8`
  and 13/trixie `04B54C3CDCA79751B16BC6B5225629DF75B188BD`. Both fingerprints were checked
  against ftp-master.debian.org and keyserver.ubuntu.com.
- **InRelease.** forky at snapshot `20261030T000000Z` (`Date: Thu, 29 Oct 2026 20:22:16 UTC`),
  checked with `gpgv`, with `VALIDSIG` required on one of those keys.
- **Indices and files.** `main/binary-arm64/Packages.xz` and `main/source/Sources.xz` are checked
  against the SHA-256 values in the signed InRelease. Every `.deb` and source file is then
  checked against those indices. Each SHA-256 is also pinned in the script.
  `downloads/adbd-debian/debs/MANIFEST.tsv` lists the packages.

The source files:

| File | SHA-256 |
| --- | --- |
| `android-platform-tools_34.0.5-13.dsc` | `06acaffb158b4045325222183ffe09ede5b8f6f6f38a8d873f44b4486e57d776` |
| `android-platform-tools_34.0.5.orig.tar.xz` | `4893f6a85b205f1df2c35cde5d6ca3bedd5e9f19afdb3b5ac781e647aa2243f4` |
| `android-platform-tools_34.0.5-13.debian.tar.xz` | `5886a4353775bdb373af5edcf56ada70b88e19b3312f7d64905210c855a972bf` |

`scripts/build-adbd.sh` cross-compiles on the laptop. It uses host `clang`/`lld` against a
Debian forky arm64 sysroot made by unpacking the verified `.deb`s; no maintainer scripts run. It
runs Debian's own `debian/system/{libcrypto_utils,libadb,adbd}.mk` with Debian's flags. The
`.pb.cc` files are regenerated with the sysroot's protoc 3.21.12 under `qemu-aarch64-static`.
Patches are applied in this order:

1. Debian's `debian/patches/series`, **without** `adbd-don-t-require-authorization-on-Linux.patch`.
   The script fails if that patch disappears from the series, or if an unconditional
   `auth_required = false` survives.
2. `scripts/adbd/patches/`:
   - `0001`: authorized keys are read from **`/etc/adbd/adb_keys`** on Linux, instead of
     `/adb_keys` and `/data/misc/adb/adb_keys`.
   - `0002`: no implicit TCP listener on Linux; TCP only with `ADBD_PORT`. It also takes
     `ro.product.{name,model,device}` from `ADBD_PRODUCT_*`, so `adb devices -l` shows
     `product:thinksmart model:ThinkSmart_View device:cd-18781y`.
   - `0003`: `adb reboot [arg]` runs `/opt/adbd/libexec/adbd-reboot`, which calls
     `systemctl reboot [--reboot-argument=arg]`, instead of `/system/bin/reboot`. Shells get
     `TMPDIR=/tmp`.
   - `0004`: an `#include <limits.h>` that libstdc++ 16 no longer pulls in.

The result is version `34.0.5-13+tsv1`, which reports "Android Debug Bridge Daemon version 1.0.41".
It goes into the image as:

| Path | What |
| --- | --- |
| `/opt/adbd/bin/adbd` | the daemon, RUNPATH `/opt/adbd/lib` |
| `/opt/adbd/lib/` | the private libraries, RUNPATH `$ORIGIN`: `libbase.so.0`, `libcutils.so.0`, `liblog.so.0` (android-platform-tools 1:34.0.5-13), `libcrypto.so.0`, `libssl.so.0` (BoringSSL, android-libboringssl 14.0.0+r45-3+b2) and `libprotobuf.so.32` (3.21.12-17). Arch has none of these sonames, and nothing else on the system looks in this directory. |
| `/opt/adbd/libexec/adbd-reboot` | reboot helper |
| `/opt/adbd/BUILDINFO`, `NOTICE` | the build record (patches, package hashes, file hashes) and the licence |
| `/etc/adbd/adb_keys` | root:root 0644. The laptop's `~/.android/adbkey.pub` (`ADB_PUBKEY=` to use another; `build-image.sh` checks that it decodes to a 524-byte Android RSA key). More keys go one per line. |
| `/etc/systemd/system/tsv-adbd.service` | enabled in `sysinit.target` |

Everything else adbd links comes from Arch Linux ARM: glibc 2.43, libstdc++/libgcc_s (gcc
16.1), brotli, lz4, zstd, libsystemd and zlib. Debian forky has the same glibc (2.43) and gcc
(16.2) series. The highest symbol versions needed are `GLIBC_2.38`, `GLIBCXX_3.4.32` and
`CXXABI_1.3.15`. Arch provides `GLIBC_2.43`, `GLIBCXX_3.4.35` and `CXXABI_1.3.17`.
`build-rootfs.sh` runs `ld-linux-aarch64.so.1 --list` and `adbd --version` inside the finished
root filesystem under qemu, and fails the build if anything is missing.

### Gadget ordering

- **Bringing adb up.** `tsv-usb-gadget run` creates `functions/ffs.adb` and mounts FunctionFS
  (`mount -t functionfs adb /dev/usb-ffs/adb`) **before** it waits for the UDC. `tsv-adbd.service`
  is ordered after the gadget, and its `ExecStartPre=tsv-usb-gadget wait-ffs` waits for that
  mount. adbd then writes its descriptors, and `ep1`/`ep2` appear.
- **First bind.** If `tsv-adbd` is enabled, the gadget waits up to 10 s for `ep1` and `ep2`, then
  links `ffs.adb` into `configs/c.1` and binds the UDC. The host then enumerates once, with all
  three functions. If adbd is not ready by then, the gadget binds NCM and ACM alone, and adds
  adb (unbind, link, rebind) as soon as the endpoints appear.
- **Recovery.** The kernel unbinds the **whole gadget** whenever adbd closes FunctionFS:
  `f_fs.c` `ffs_closed()` calls `unregister_gadget_item()`. adbd closes it when it restarts or
  crashes, and also on every host disconnect, because adbd reopens FunctionFS on
  `FUNCTIONFS_DISABLE`. So the script does not exit after binding. It checks once a second,
  using bash builtins and `sleep`. When it finds the gadget unbound, it waits up to 2 s for
  adbd's endpoints, then rebinds with adb if they are there and without adb otherwise. If adb
  binds fail, or die within 5 s, three times in a row, adb is held off for 60 s and NCM and ACM
  stay up.
- **NCM and ACM never wait on adb.** They are linked first and always, so their interface
  numbers never change. `ffs.adb` is only ever linked while adbd's descriptors exist, and a bind
  that fails with adb is retried at once without it. A missing `/opt/adbd`, a disabled or failed
  `tsv-adbd`, or a broken FunctionFS all leave plain NCM and ACM. `usb0` keeps
  `172.16.42.1/24` across rebinds, because the netdev survives.
- **Cost.** Each adbd restart, and each cable replug, re-enumerates the device on the laptop. NCM
  drops for about a second and comes back with the same address and lease.

### Verified on the laptop (not on the tablet)

- **Scratch build.** `build-image.sh` ran to completion into a scratch output, and
  `inspect-image.sh` shows the files, modes, owners, the `sysinit.target.wants` link and the key.
- **adbd under qemu.** The built adbd ran under qemu-user, chrooted into the finished root
  filesystem, with `ADBD_PORT` set, and the laptop's `adb` connected to it:
  - A client with a different key stayed `unauthorized`.
  - The laptop key got `device product:thinksmart model:ThinkSmart_View device:cd-18781y`.
  - `adb shell id` returned `uid=0(root)`, with `TMPDIR=/tmp`.
  - A 300 kB `push`/`pull` round trip compared equal.
  - Without `ADBD_PORT`, adbd opened no TCP socket.
- **The supervisor loop.** It ran against a mock configfs tree. Boot wait, late adbd, adbd
  restart, adbd gone and flap hold-off all behaved as described.
- **Scripts.** All the new and changed scripts pass `bash -n` and `shellcheck`.

### TCP (off by default)

adbd does not listen on any network socket unless you ask it to. To turn TCP on (port 5555, all
interfaces including Wi-Fi, same key authentication):

```sh
echo ADBD_PORT=5555 | sudo tee /etc/adbd/adbd.env && sudo systemctl restart tsv-adbd
# laptop: adb connect thinksmart:5555        off again: sudo rm /etc/adbd/adbd.env && sudo systemctl restart tsv-adbd
```

### Laptop side

No new VID/PID is needed and no udev rule is needed on this laptop. The adb client on Linux finds
devices by interface class `ff/42/01`, not by vendor ID. systemd 262's
`/usr/lib/udev/rules.d/70-uaccess.rules` sets `ID_DEBUG_APPLIANCE=android` for any USB device
with an `ff4201` interface and tags it `uaccess`, so the logged-in desktop user gets access to
the composite `1d6b:0104` as it is. Only if `adb devices` says `no permissions` (for example,
from a session with no seat), add a rule:

```sh
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1d6b", ATTR{idProduct}=="0104", ATTR{product}=="ThinkSmart View*", MODE="0660", GROUP="wheel"' \
  | sudo tee /etc/udev/rules.d/51-thinksmart-adb.rules && sudo udevadm control --reload && sudo udevadm trigger
```

Use:

```sh
adb devices -l      # <16 hex digits>  device usb:… product:thinksmart model:ThinkSmart_View device:cd-18781y
adb shell           # root shell (bash as /bin/sh, login profile)
adb push file /tmp/ ; adb pull /var/log/pacman.log
adb reboot          # systemctl reboot; `adb reboot bootloader|edl` passes the argument to the kernel
```

The serial number is the same one the USB descriptor carries: the first 16 hex digits of the
SHA-256 of the SoC serial, falling back to machine-id. It stays the same across reboots and
reflashes. On the device, `journalctl -u tsv-adbd -u tsv-usb-gadget` shows what happened.

## Wi-Fi

NetworkManager has no profile in the image, so Wi-Fi is unconfigured. Add one to the image file
before flashing:

```sh
rootfs/scripts/inject-wifi.sh --ssid yareyare-xd-mesh --psk -     # reads the PSK from stdin
# or: --psk 'the-psk'  (visible in ps while it runs); --image <img> for another file
```

The script finds the `tsv-root` filesystem in the MBR and writes
`/etc/NetworkManager/system-connections/<ssid>.nmconnection` with `debugfs -w` at that byte
offset, as root:root mode 0600. It checks the result with `e2fsck -fn` and never prints the
PSK. The profile has `autoconnect=true` and `autoconnect-retries=0`, which means retry forever,
so it reconnects after a router restart. Wi-Fi power save is off (`wifi.powersave=2`). The
image's `.sha256` no longer matches after injection, which is expected. Tested on a copy of the
image with a dummy PSK.

## Boot splash and idle screen

The screen shows the **ai&** wordmark from power-on (as soon as the panel is up in the
initramfs) until a desktop exists: first as a Plymouth boot splash, then, once the system is up,
as a still image on the framebuffer. White wordmark on pure black (`#000000`).

| | |
| --- | --- |
| Source | `assets/aiand-wordmark.svg`, a copy of `keiyo-badges/media/brand/aiand-wordmark.svg` (1280x420, no `viewBox`) |
| Recoloured | `assets/aiand-wordmark-white.svg`: the four `#151517` shapes become `#ffffff`. The fifth shape, the red accent stripe `#C70007`, is **kept red**. `ACCENT=white scripts/render-logo.sh` makes it white as well |
| Size on screen | 520x171 px (65 % of the 800 px width, aspect kept), centred at +140+554; about 70x23 mm at 189 ppi |
| Previews | `assets/preview-splash-800x1280.png` (the splash, progress line drawn at 40 %) and `assets/preview-idle-800x1280.png` (the idle screen, also the last splash frame at shutdown) |
| Regenerate | `scripts/render-logo.sh` (laptop: `rsvg-convert`, ImageMagick `magick`, `python3`, `zstd`). Its outputs are checked in, so `build-image.sh` needs none of these |

### Boot splash (Plymouth)

- **Package.** `plymouth` from Arch Linux ARM `extra` (26.134.222). It pulls in cairo, pango,
  fontconfig, freetype, harfbuzz, libx11, libxkbcommon, xkeyboard-config and `adwaita-fonts`,
  all of which Omarchy needs anyway. Root grows by about **76 MiB** of used blocks (28 packages, 61 MiB installed size; xkeyboard-config 10 MiB, libx11 10 MiB, adwaita-fonts 7 MiB and harfbuzz 6 MiB are the largest).
- **Theme `aiand`** (`scripts/overlay/usr/share/plymouth/themes/aiand/`), script plugin:
  - `aiand.script`: black background, `logo.png` centred, and a 160x3 progress line 110 px under
    the wordmark (track white at 20 % opacity, fill at 75 %, never moves backwards). The line is
    only drawn in boot mode; shutdown and reboot show the wordmark alone. Messages (for example
    from fsck) appear in small grey text under the line, and a password prompt, should one ever
    appear, is shown rather than left invisible. On a screen that is not 800 px wide the wordmark
    is rescaled to 65 % of the width.
  - `logo.png` (520x171, white, transparent) and `bar.png` (one white pixel, scaled for the line).
  - No Lenovo, Arch or other branding. The Arch logo PNG that the stock mkinitcpio hook copies
    is in the initramfs but the theme never loads it.
- **`/etc/plymouth/plymouthd.conf`**: `Theme=aiand`, `DeviceScale=1` (draw 1:1; the panel
  reports no physical size), `DeviceTimeout=8`, `ShowDelay=0`.
- **Initramfs.** `HOOKS=(base udev modconf plymouth tsv-subpart fsck)`, now set in
  `/etc/mkinitcpio.conf.d/zz-tsv-hooks.conf`. That drop-in is read last, so a later drop-in
  (Omarchy writes `omarchy_hooks.conf` with its own `HOOKS=`, without `tsv-subpart`) cannot
  remove the hook that finds root. `plymouth` comes after `udev`: by then `msm`, the panel and
  WLED (`MODULES`) are loaded and udev has created `/dev/dri/card0`. The initramfs grows from
  10.9 MiB to **13.4 MiB** (14090626 bytes; 53 MiB uncompressed) (zstd -19); kernel + DTB + initramfs stay well inside lk2nd's 50 MiB.
  `build-rootfs.sh` fails the build if `plymouth-set-default-theme` is not `aiand`, or if
  `lsinitcpio` does not list plymouthd, `script.so`, the DRM renderer, the theme files,
  `plymouthd.conf`, and the `plymouth` and `tsv-subpart` runtime hooks.
- **Kernel command line**: `... console=tty0 quiet splash loglevel=4` (was `loglevel=7`).
  `splash` tells Plymouth to draw. `quiet` and `loglevel=4` keep kernel warnings and notices off
  the screen; errors (`KERN_ERR` and worse), systemd unit failures and the initramfs `err`
  messages still reach the console, and everything stays in `dmesg` and the journal
  (`journalctl -b -k`, `journalctl -b`). `console=tty0` stays; there is no serial console
  argument (the UART is disabled in the DTS). For a verbose boot, drop `quiet splash` and set
  `loglevel=7` in `/boot/extlinux/extlinux.conf`; `plymouth.enable=0` turns Plymouth off
  completely.
- **It cannot block the boot.** `plymouthd` daemonizes in the initramfs hook and boot carries
  on at once. If DRM never appears (panel or LAB/IBB not probing), it waits `DeviceTimeout`
  (8 s) in the background, then falls back to the text splash on tty1. Nothing in USB
  networking, sshd, adbd or the gadget is ordered after any Plymouth unit. The gettys, including
  `serial-getty@ttyGS0` on the USB ACM port, wait for `plymouth-quit-wait.service`, as on any
  Arch system. Arch ships that unit with `TimeoutSec=0` (forever), so the drop-in
  `plymouth-quit-wait.service.d/10-tsv-timeout.conf` caps it at 60 s; the gettys only have
  `After=` on it and start anyway. `plymouth-quit.service` has its own 20 s timeout.

### Idle screen (`tsv-idle-screen`)

There is no desktop until Omarchy (milestone 7), so after boot the framebuffer would show a
text login on tty1. Instead it shows the same wordmark (`assets/preview-idle-800x1280.png`).
This is the lightest thing that works: a shell script, two pre-rendered raw frames, and the
fbdev emulation that is already in the kernel (`CONFIG_DRM_FBDEV_EMULATION=y`,
`CONFIG_FRAMEBUFFER_CONSOLE=y`). No compositor, no DRM client, nothing left running.

- **Trigger.** `/etc/udev/rules.d/90-tsv-idle-screen.rules` adds `SYSTEMD_WANTS` for
  `tsv-idle-screen.service` when `fb0` appears (udev's coldplug replays this at boot). If the
  panel never probes, there is no `fb0`, the unit is never pulled in, and nothing waits for it.
  The unit has no `[Install]` section; it is not in `multi-user.target`.
- **Unit.** `Type=oneshot`, `RemainAfterExit=yes`, ordered after `plymouth-quit.service` (Plymouth
  holds DRM master until then) and `systemd-user-sessions.service`.
  `ConditionPathExists=/dev/fb0`.
- **`tsv-idle-screen start`** (`/usr/local/sbin/tsv-idle-screen`):
  1. Unbinds fbcon from the framebuffer (`echo 0 > /sys/class/vtconsole/vtconN/bind` for the
     "frame buffer device" console). The VTs move to the dummy console, so the getty prompt,
     the cursor and kernel messages no longer draw over the image. Nothing is taken from a tty:
     `getty@tty1` keeps running unseen, and `/dev/console`, `serial-getty@ttyGS0`, sshd and adbd
     are untouched. Console blanking is already off (the kernel default `consoleblank=0`), and
     with fbcon unbound the VT blank timer cannot reach the framebuffer anyway.
  2. Reads `/sys/class/graphics/fb0/{modes,virtual_size,bits_per_pixel,stride}` and writes the
     matching frame: `idle-800x1280.xrgb8888.zst` for 32 bpp (msm's fbdev: XRGB8888, pitch
     `ALIGN(800, 32) * 4` = 3200) or `idle-800x1280.rgb565.zst` for 16 bpp, decompressed with
     `zstd` straight into `/dev/fb0`. A padded pitch is handled row by row with `dd`. Any other
     mode is filled black and logged. msm's fbdev uses deferred I/O with a dirty callback, so a
     plain `write()` reaches the scanout buffer.
  3. Lowers the backlight to `IDLE_BRIGHTNESS` from `/etc/tsv/idle-screen.conf` (default 2000
     of 4095) if it is brighter, and remembers the old value. The script never goes below 1400,
     because the PMI8950 WLED turns the panel off below about 1200
     (`devices/backlight/BRIEF.md`). An empty `IDLE_BRIGHTNESS=` leaves the backlight alone.
  Every failure is logged (`journalctl -u tsv-idle-screen`) and the script still exits 0.
- **`tsv-idle-screen stop`** (`ExecStop`) restores the brightness and rebinds fbcon, so the
  text console comes back:

  ```sh
  sudo systemctl stop tsv-idle-screen          # text console now, image again next boot
  sudo systemctl mask --now tsv-idle-screen    # never again (unmask to undo)
  sudo systemctl restart tsv-idle-screen       # redraw
  ```

- **Hand-over to a desktop.** `ConditionPathExists=!/etc/systemd/system/display-manager.service`:
  once a display manager is enabled (Omarchy enables SDDM as `display-manager.service`), the
  idle screen no longer starts at all, and it is ordered `Before=display-manager.service`.
  `Conflicts=display-manager.service` is deliberately not used: a late, udev-triggered start
  would then stop the display manager. If a compositor is started some other way (for example
  from a getty autologin), it simply takes DRM master and covers the framebuffer; mask the unit
  as above to keep fbcon bound for that case too.
- **Tests without hardware.** `TSV_IDLE_SYSFS`, `TSV_IDLE_DEV`, `TSV_IDLE_DIR`,
  `TSV_IDLE_STATE` and `TSV_IDLE_FB` point the script at a fake sysfs and `/dev`.

### After Omarchy

Omarchy installs its own theme (on the laptop: `/usr/share/omarchy/default/plymouth/omarchy.plymouth`,
copied to `/usr/share/plymouth/themes/omarchy` and selected with `plymouth-set-default-theme`).
To put `aiand` back:

```sh
sudo plymouth-set-default-theme -R aiand     # -R runs mkinitcpio -P (the tsv preset)
lsinitcpio /boot/initramfs-tsv.img | grep -E 'themes/aiand|hooks/(plymouth|tsv-subpart)'
```

Check at the same time that `/etc/mkinitcpio.conf.d/zz-tsv-hooks.conf` is still there and is
still the last file in that directory; without `tsv-subpart` the device does not find its root.

### Verified on the laptop (not on the tablet)

- **Render.** `scripts/render-logo.sh` produced the previews. The theme was then run with the
  laptop's own Plymouth (same version, 26.134.222) through its X11 renderer in an 800x1280
  `Xvfb`, inside `unshare -rm` with the theme bind-mounted over `/usr/share/plymouth/themes`:
  - the shutdown frame is identical to `preview-idle-800x1280.png` (ImageMagick AE < 1 pixel);
  - the boot frame matches `preview-splash-800x1280.png` apart from the progress fill length
    (Plymouth's own estimate) and the test message; the track is grey 51 and the fill 204, as in
    the preview;
  - in a 1600x1400 `Xvfb` the wordmark was rescaled to 1040 px (65 %) and stayed centred.
- **Framebuffer writer.** `tsv-idle-screen start` against a fake sysfs and a file as `/dev/fb0`:
  at 32 bpp with pitch 3200 and with a padded pitch of 3328 the frame decodes (as BGRX) to
  exactly `preview-idle-800x1280.png`; at 16 bpp the RGB565 frame matches within 3 %; fbcon
  was unbound and the dummy console left bound; brightness went 3000 -> 2000 and `stop`
  restored 3000 and rebound fbcon; without `fb0` it logged and exited 0.
- **Scratch build** (`TSV_WORK`/`TSV_OUT`, no password, deleted afterwards) completed. Under
  qemu in the built root: `plymouth-set-default-theme` prints `aiand`; `lsinitcpio` lists
  `plymouthd`, `script.so`, `renderers/drm.so` and `frame-buffer.so`, `label-freetype.so`, the
  four `themes/aiand/` files, `plymouthd.conf`, and `hooks/plymouth` beside `hooks/tsv-subpart`
  and the 18 display modules; `systemd-analyze verify tsv-idle-screen.service` reports nothing
  for the unit; `udevadm verify` passes the rule; both raw frames pass `zstd -t`. The image's
  `extlinux.conf` carries `quiet splash loglevel=4`.

### Only the tablet can confirm

- That the panel is up in the initramfs early enough for the splash to appear, rather than
  Plymouth's 8 s fallback to text. That depends on msm, the DSI panel and LAB/IBB probing.
- That `fb0` on hardware really is 800x1280 at 32 bpp with pitch 3200 (the script copes with
  other pitches and with 16 bpp), and that unbinding fbcon leaves the display on and the image
  visible.
- That brightness 2000 is a comfortable idle level, and whether the 1200 cutoff is real.
- The colours of the red accent on this panel.

## Rebuilding

```sh
cd /home/jethac/Projects/lenovo-8
# optional: export TSV_JETHAC_PASSWORD='…'   (only a hash reaches the image)
# only after changing the logo: rootfs/scripts/render-logo.sh   (outputs are checked in)
rootfs/scripts/build-image.sh              # about 10–15 min; KEEP_WORK=1 keeps rootfs/work
rootfs/scripts/inspect-image.sh rootfs/out/thinksmart-alarm-system.img
rootfs/scripts/inject-wifi.sh --ssid yareyare-xd-mesh --psk -
```

What `build-image.sh` does:

1. `fetch-alarm.sh` downloads the Arch Linux ARM tarball, `.md5` and `.sig` into
   `downloads/` and verifies them. It skips the download when the files are present and
   verify.
2. `fetch-adbd.sh` and `build-adbd.sh` fetch, verify and cross-build adbd into `work/adbd`
   (see [adb](#adb)).
3. `extract-firmware.sh` checks the backup images and extracts the firmware into
   `work/firmware`, using `fatextract.py` and `ath10k-fwpack.py`.
4. Inside `unshare --user --map-root-user --map-auto --mount --pid --fork`:
   - `build-rootfs.sh` runs `bsdtar` extraction, then a chroot that reaches aarch64 binaries
     through qemu-aarch64 binfmt. The chroot gets a private minimal `/dev` and no `/sys`, so
     package hooks cannot touch host devices.
   - In that chroot it runs pacman, `modules_install`, users and services, and mkinitcpio.
   - `make-image.sh` creates the filesystems with `mke2fs -d`, writes the MBR with `sfdisk` on
     the image file, and places the filesystems with `dd conv=sparse`.
5. It writes the SHA-256, the partition listing and the firmware manifest to `out/`, then
   removes `work/`.

Host requirements: `unshare`/`newuidmap` with a `/etc/subuid` range, qemu-aarch64 binfmt with
the `F` flag and `qemu-aarch64-static`, `bsdtar`, e2fsprogs, util-linux, `zstd`, `xz`, `gpg`/`gpgv`,
`curl`, `python3`, `openssl`, `patch`, `make`, binutils `ar`, `patchelf`, and clang/LLVM/lld (the
kernel's `modules_install` and the adbd cross build). No sudo is needed. Nothing is mounted on the host.

Environment: `TSV_JETHAC_PASSWORD` (see Users), `PUBKEY` (SSH key, default
`~/.ssh/id_ed25519_stadia_testbed.pub`), `ADB_PUBKEY` (default `~/.android/adbkey.pub`),
`KEEP_WORK=1`, and `TSV_WORK`/`TSV_OUT` to build into scratch directories instead of
`work/` and `out/`.

Writing the image is part of the flashing checklist, not this milestone. It would be
`edl w system out/thinksmart-alarm-system.img`, after lk2nd from msm8916-mainline is in
`boot`. With the stock GPT, the 1.5 GiB image fits the existing `system` partition.

## Not done, or not verified

Nothing below has been checked on hardware.

- **The display will probably stay dark.** The kernel config does not set
  `CONFIG_REGULATOR_QCOM_LABIBB`. The panel node takes `vsp-supply = <&lab>` and
  `vsn-supply = <&ibb>` (PMI8950 LAB/IBB), so `devm_regulator_bulk_get` in
  `panel-lenovo-cd-18781y-ft8201` will defer forever. Every other msm8953 board config in
  `arch/arm64/configs/` (vince, mido, daisy, potter, …) enables it. The kernel has to be
  rebuilt with `CONFIG_REGULATOR_QCOM_LABIBB=y` (or `=m`, added to the initramfs `MODULES`).
  This does not affect USB networking or SSH.
- `&uart_0` in the device DTS has `status = "enabled"`. Linux only accepts `"okay"`/`"ok"`, so
  the debug UART (`ttyMSM0`) is probably absent. `console=tty0` is used.
- **USB gadget mode is unproven on this unit.** The USB brief's open questions are unanswered:
  whether the side port carries data, and whether Type-C CC detection matters. If DWC3 comes up
  in host mode, the role can be forced with
  `echo device > /sys/class/usb_role/*/role` (needs console access).
- **Wi-Fi firmware container features.** `wowlan,ignore-otp,mfp` is an inference. If ath10k
  fails, rebuild with `--features ignore-otp`, the upstream-tested set, or without
  `--otp`.
- **The BT file names.** `00150100` comes from upstream mailing-list text, not from this
  unit's controller.
- The ath10k GTK rekey patch (milestone 6) is not carried; the kernel is used as built.
- There is no zram or swap yet, and nothing from milestone 8 (sensors, audio UCM, daemons).
- **Hardcoded paths.** The initramfs preset and extlinux entry name the kernel version
  `7.3.0-g755ffc44d5d8`. Installing a new kernel means updating `/boot` (Image.gz, DTB),
  `/etc/mkinitcpio.d/tsv.preset`, and running `mkinitcpio -P`.
- **adb on hardware:**
  - The adb function, enumeration with NCM + ACM + adb on the DWC3, and the
    rebind-after-unbind loop are untested on hardware. They were only exercised against a mock
    configfs tree.
  - Whether `adb reboot bootloader`/`edl` reach lk2nd or EDL depends on the PON reboot-mode
    support in the DTS.
- Removing `linux-firmware` means nothing beyond the files above is available. That is
  deliberate: this board needs no generic firmware.
