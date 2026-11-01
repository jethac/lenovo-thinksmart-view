#!/usr/bin/env bash
# Build the Arch Linux ARM root filesystem tree for the ThinkSmart View.
# Must run as root inside a user namespace (build-image.sh arranges this with
# unshare --map-root-user --map-auto --mount --pid --fork). Nothing here needs
# real root: aarch64 binaries run through the host's qemu-aarch64 binfmt (F).
#
#   build-rootfs.sh TARBALL ROOTFS_DIR BOOTFS_DIR FIRMWARE_DIR KSRC KBUILD PUBKEY \
#                   [ADBD_STAGE ADB_PUBKEY [STRAYLIGHT_STAGE]]
#
# ADBD_STAGE is build-adbd.sh's stage/ tree (/opt/adbd); ADB_PUBKEY is the
# adb public key (adbkey.pub) installed as /etc/adbd/adb_keys.
# STRAYLIGHT_STAGE is build-straylight.sh's tree (the voice assistant).
#
# Environment: TSV_JETHAC_HASH (optional) - a crypt(3) hash for jethac.
set -euo pipefail

TARBALL=$1 R=$2 BOOT=$3 FW=$4 KSRC=$5 KBUILD=$6 PUBKEY=$7
ADBD_STAGE=${8:-} ADB_PUBKEY=${9:-} STRAYLIGHT_STAGE=${10:-}
HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY=$HERE/overlay
KVER=$(cat "$KBUILD/include/config/kernel.release")
DTB=apq8053-lenovo-cd-18781y.dtb

[[ $(id -u) == 0 ]] || { echo "run inside the user namespace" >&2; exit 1; }

# ---------------------------------------------------------------- extract
rm -rf "$R" "$BOOT"
mkdir -p "$R" "$BOOT"
bsdtar -xpf "$TARBALL" --numeric-owner -C "$R"

# ---------------------------------------------------------------- chroot
# Minimal /dev (individual nodes bound from the host) and no /sys, so package
# hooks such as systemd-tmpfiles cannot touch the host's devices.
mount -t tmpfs -o mode=0755 tmpfs "$R/dev"
for n in null zero full random urandom tty; do
    touch "$R/dev/$n"
    mount --bind "/dev/$n" "$R/dev/$n"
done
mkdir -p "$R/dev/shm" "$R/dev/pts"
mount -t tmpfs tmpfs "$R/dev/shm"
ln -s /proc/self/fd "$R/dev/fd"
ln -s /proc/self/fd/0 "$R/dev/stdin"
ln -s /proc/self/fd/1 "$R/dev/stdout"
ln -s /proc/self/fd/2 "$R/dev/stderr"
mount -t proc proc "$R/proc"
mount -t tmpfs tmpfs "$R/run"
mount -t tmpfs tmpfs "$R/tmp"
mv "$R/etc/resolv.conf" "$R/etc/resolv.conf.tsv-orig" 2>/dev/null || true
cp -L /etc/resolv.conf "$R/etc/resolv.conf"

in_root() {
    chroot "$R" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
        HOME=/root LANG=C.UTF-8 TERM=dumb /bin/bash -euo pipefail -c "$1"
}

PAC="pacman --noconfirm --disable-sandbox"
# In a chroot without its own mount namespace root, pacman cannot map the
# cache dir to a mount point and CheckSpace aborts; disable it for the build.
sed -i 's/^CheckSpace/#CheckSpace-tsvbuild/' "$R/etc/pacman.conf"
in_root "pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1"
# Generic-board kernel and the full linux-firmware set are not used here.
in_root "pacman -D --asexplicit mkinitcpio >/dev/null"
in_root "$PAC -Rns linux-aarch64 \$(pacman -Qq | grep -E '^linux-firmware') netctl dhcpcd"
# plymouth: ai& boot splash (theme in the overlay; see README "Boot splash and idle screen").
in_root "$PAC -Syu --needed mkinitcpio networkmanager dnsmasq sudo wireless-regdb iw plymouth"
# Audio (speaker through the ADSP and TAS5782M, microphones) and camera userspace:
# PipeWire with WirePlumber and the ALSA UCM profiles the overlay adds to, plus the
# ALSA and V4L2 command-line tools used to check them.
in_root "$PAC -S --needed pipewire wireplumber alsa-ucm-conf alsa-utils v4l-utils"
# The Straylight voice assistant: libinput (touch, for Slint's linuxkms backend;
# pulls in mtdev, libwacom, libgudev, lua54) and the Noto fonts (Latin, and CJK
# for recognised and spoken Japanese and Chinese). See README "Voice assistant".
in_root "$PAC -S --needed libinput noto-fonts noto-fonts-cjk"
in_root "$PAC -Scc >/dev/null; rm -rf /var/cache/pacman/pkg/*"

sed -i 's/^#CheckSpace-tsvbuild/CheckSpace/' "$R/etc/pacman.conf"

# ---------------------------------------------------------------- kernel modules + firmware
make -s -C "$KSRC" O="$KBUILD" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$R/usr" \
    INSTALL_MOD_STRIP=1 modules_install
rm -f "$R/usr/lib/modules/$KVER/build" "$R/usr/lib/modules/$KVER/source"
in_root "depmod -a $KVER"

mkdir -p "$R/usr/lib/firmware"
cp -a --no-preserve=ownership "$FW/." "$R/usr/lib/firmware/"
chown -R 0:0 "$R/usr/lib/firmware"

# ---------------------------------------------------------------- configuration
cp -a --no-preserve=ownership "$OVERLAY/." "$R/"
# tsv-idle-rotate (the idle screen's DRM/KMS daemon): cross-compiled with host
# clang/lld against this very tree (glibc and libdrm, headers included, are in it
# by now). See README "Boot splash and idle screen".
"$HERE/idle-rotate/build.sh" --sysroot "$R" "$R/usr/local/libexec"
chown -R 0:0 "$R/etc/systemd" "$R/etc/NetworkManager" "$R/etc/ssh/sshd_config.d" \
    "$R/etc/sudoers.d" "$R/etc/tsv" "$R/etc/initcpio" "$R/etc/mkinitcpio.d" \
    "$R/usr/local/sbin" "$R/usr/local/libexec" "$R/etc/hostname" "$R/etc/locale.conf" "$R/etc/vconsole.conf" \
    "$R/etc/fstab" "$R/etc/mkinitcpio.conf" "$R/etc/mkinitcpio.conf.d" "$R/etc/plymouth" "$R/etc/udev/rules.d" \
    "$R/usr/share/plymouth/themes/aiand" "$R/usr/share/tsv" "$R/etc/conf.d/wireless-regdom"
chmod 0440 "$R/etc/sudoers.d/10-wheel"
chmod 0700 "$R/etc/NetworkManager/system-connections"
rm -f "$R/etc/NetworkManager/system-connections/.keep"

ln -sf /usr/share/zoneinfo/Asia/Tokyo "$R/etc/localtime"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$R/etc/locale.gen"
in_root "locale-gen >/dev/null"

# Users: drop the stock alarm account, lock root, add jethac (wheel; audio for the
# speaker and microphones, video for DRM and the camera, input for buttons and
# the lens switch: the device runs one app with no desktop session to grant them).
in_root "userdel -r alarm 2>/dev/null || userdel alarm; rm -rf /home/alarm"
# Replace the stock root:root hash entirely (not just a '!' prefix).
in_root "usermod -p '!*' root"
in_root "useradd -m -u 1000 -U -G wheel,audio,video,input -s /bin/bash jethac"
if [[ -n ${TSV_JETHAC_HASH:-} ]]; then
    printf 'jethac:%s\n' "$TSV_JETHAC_HASH" | chroot "$R" /usr/bin/chpasswd -e
    echo "build-rootfs: jethac password set from TSV_JETHAC_PASSWORD (hash only)"
else
    # '*' (not '!'): no password can match, but sshd does not treat the account
    # as locked, so key logins keep working even with UsePAM=no.
    in_root "usermod -p '*' jethac"
    echo "build-rootfs: TSV_JETHAC_PASSWORD not set; jethac password login is LOCKED (key only)"
fi
install -d -m 0700 "$R/home/jethac/.ssh"
install -m 0600 "$PUBKEY" "$R/home/jethac/.ssh/authorized_keys"
in_root "chown -R jethac:jethac /home/jethac/.ssh"

# adbd (USB FunctionFS, key authentication, root shell; see README "adb").
ADB_UNITS=""
if [[ -n $ADBD_STAGE ]]; then
    cp -a --no-preserve=ownership "$ADBD_STAGE/." "$R/"
    chown -R 0:0 "$R/opt/adbd"
    install -d -m 0755 "$R/etc/adbd"
    install -m 0644 "$ADB_PUBKEY" "$R/etc/adbd/adb_keys"
    chown -R 0:0 "$R/etc/adbd"
    # Links and runs against the Arch libraries in the image (through qemu).
    in_root "! /usr/lib/ld-linux-aarch64.so.1 --list /opt/adbd/bin/adbd | grep -F 'not found'"
    in_root "/opt/adbd/bin/adbd --version"
    ADB_UNITS=tsv-adbd
else
    rm -f "$R/etc/systemd/system/tsv-adbd.service"
    echo "build-rootfs: no adbd stage given; image has no adbd"
fi

# The Straylight voice assistant (README "Voice assistant"): binaries, models,
# units, configs, udev rule, polkit rule, D-Bus policy, sysusers file. File by
# file with install(1), so directories that packages own (polkit's rules.d is
# root:polkitd 0750) keep their owner and mode.
VOICE_UNITS=""
if [[ -n $STRAYLIGHT_STAGE ]]; then
    (cd "$STRAYLIGHT_STAGE" && find . -type f -printf '%P\t%m\n') | while IFS=$'\t' read -r f m; do
        install -D -o 0 -g 0 -m "$m" "$STRAYLIGHT_STAGE/$f" "$R/$f"
    done
    # User straylight-wifi and group straylight (the screen's socket group).
    in_root "systemd-sysusers /usr/lib/sysusers.d/straylight-wifi.conf"
    in_root "id straylight-wifi && getent group straylight | grep -q straylight-wifi"
    for b in straylight-voice straylight-voicectl straylight-listen straylight-aiand straylight-wifi; do
        in_root "! /usr/lib/ld-linux-aarch64.so.1 --list /usr/local/bin/$b | grep -F 'not found'"
    done
    for l in libinput.so.10 libxkbcommon.so.0 libudev.so.1; do
        in_root "/usr/lib/ld-linux-aarch64.so.1 --list /usr/local/bin/straylight-voice | grep -q '$l => /'"
    done
    in_root "/usr/lib/ld-linux-aarch64.so.1 --list /usr/local/bin/straylight-listen | grep -q 'libasound.so.2 => /'"
    in_root "udevadm verify /etc/udev/rules.d/91-straylight-voice.rules"
    VOICE_UNITS="straylight-voice straylight-listen straylight-aiand straylight-wifi"
else
    echo "build-rootfs: no Straylight stage given; image has no voice assistant"
fi

# Services.
# tsv-idle-screen has no [Install]: udev starts it when fb0 appears. With the
# voice assistant enabled (display-manager.service alias) and its 91 udev rule,
# it is not started at all; it stays installed as the fallback.
in_root "systemctl enable sshd NetworkManager systemd-timesyncd tsv-usb-gadget tsv-usb-dhcp tsv-growroot tsv-pacman-keyring tsv-zram $ADB_UNITS $VOICE_UNITS"
in_root "systemctl disable systemd-networkd systemd-networkd.socket >/dev/null 2>&1 || true"
in_root "systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service"

# ---------------------------------------------------------------- initramfs + boot files
in_root "mkinitcpio -k $KVER -g /boot/initramfs-tsv.img"
# The splash must actually be in there: theme, its images and the DRM renderer.
in_root "[ \"\$(plymouth-set-default-theme)\" = aiand ]"
in_root "lsinitcpio /boot/initramfs-tsv.img > /tmp/initramfs.list"
for f in usr/bin/plymouthd usr/lib/plymouth/script.so usr/lib/plymouth/renderers/drm.so \
    usr/share/plymouth/themes/aiand/aiand.plymouth usr/share/plymouth/themes/aiand/aiand.script \
    usr/share/plymouth/themes/aiand/logo.png usr/share/plymouth/themes/aiand/bar.png \
    etc/plymouth/plymouthd.conf hooks/plymouth hooks/tsv-subpart; do
    grep -qx "$f" "$R/tmp/initramfs.list" || { echo "initramfs lacks $f" >&2; exit 1; }
done
in_root "systemd-analyze verify --man=no tsv-idle-screen.service"
if [[ -n $VOICE_UNITS ]]; then
    in_root "systemd-analyze verify --man=no straylight-voice.service straylight-listen.service straylight-aiand.service straylight-wifi.service"
    [[ $(readlink "$R/etc/systemd/system/display-manager.service") == /etc/systemd/system/straylight-voice.service ]] ||
        { echo "build-rootfs: display-manager.service alias missing" >&2; exit 1; }
    [[ $(chroot "$R" systemctl get-default) == graphical.target ]] ||
        { echo "build-rootfs: default target is not graphical.target" >&2; exit 1; }
fi
# tsv-idle-rotate links against the image's libraries and renders (through qemu).
in_root "! /usr/lib/ld-linux-aarch64.so.1 --list /usr/local/libexec/tsv-idle-rotate | grep -F 'not found'"
in_root "/usr/local/libexec/tsv-idle-rotate --render 30 /tmp/idle-rotate.raw && [ \$(stat -c %s /tmp/idle-rotate.raw) = 4096000 ]; rm -f /tmp/idle-rotate.raw"
echo "build-rootfs: initramfs $(stat -c %s "$R/boot/initramfs-tsv.img") bytes, splash theme aiand"
mv "$R/boot/initramfs-tsv.img" "$BOOT/"
install -m 0644 "$KBUILD/arch/arm64/boot/Image.gz" "$BOOT/Image.gz"
printf '%s\n' "$KVER" > "$BOOT/kernel.release"
install -D -m 0644 "$KBUILD/arch/arm64/boot/dts/qcom/$DTB" "$BOOT/dtbs/qcom/$DTB"
install -D -m 0644 "$KBUILD/.config" "$BOOT/config-$KVER"
mkdir -p "$BOOT/extlinux"
cat > "$BOOT/extlinux/extlinux.conf" <<EOF
# Read by lk2nd (lk2nd/boot/extlinux.c). Paths are relative to this ext2
# filesystem, which is mounted at /boot on the running system.
default arch
label arch
	linux /Image.gz
	fdt /dtbs/qcom/$DTB
	initrd /initramfs-tsv.img
	append root=LABEL=tsv-root rw tsv_subpart=PARTLABEL=system console=tty0 quiet splash loglevel=4
EOF

# ---------------------------------------------------------------- scrub per-image state
rm -f "$R"/etc/ssh/ssh_host_*
rm -rf "$R/etc/pacman.d/gnupg"
printf 'uninitialized\n' > "$R/etc/machine-id"
rm -f "$R/var/lib/systemd/random-seed"
rm -rf "$R"/var/log/journal/* "$R"/var/log/pacman.log "$R"/root/.bash_history
# The voice assistant's state (ai& account, sound settings, recordings) is made
# on the device; none of it is shipped.
rm -rf "$R/var/lib/straylight-aiand" "$R/var/lib/straylight-listen" "$R/var/lib/private/straylight-"*
rm -f "$R/etc/resolv.conf"
if [[ -e $R/etc/resolv.conf.tsv-orig || -L $R/etc/resolv.conf.tsv-orig ]]; then
    mv "$R/etc/resolv.conf.tsv-orig" "$R/etc/resolv.conf"
fi
rm -rf "$R/boot"/*

umount -R "$R/dev" "$R/proc" "$R/run" "$R/tmp" 2>/dev/null || umount -lR "$R/dev" || true
echo "build-rootfs: root $(du -sh "$R" | cut -f1), boot $(du -sh "$BOOT" | cut -f1), kernel $KVER"
