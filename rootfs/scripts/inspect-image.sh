#!/usr/bin/env bash
# Print the partition table and filesystem facts of a ThinkSmart system image
# (read only; uses sfdisk/debugfs with byte offsets, nothing is mounted).
#   inspect-image.sh IMAGE
set -euo pipefail
IMG=$1
echo "# $(basename "$IMG")"
echo "size: $(stat -c %s "$IMG") bytes ($(($(stat -c %s "$IMG") / 1048576)) MiB), allocated $(du -h "$IMG" | cut -f1)"
echo
echo "## sfdisk -l"
sfdisk -l "$IMG"
echo
echo "## sfdisk -d"
sfdisk -d "$IMG"
i=0
while read -r start size; do
    i=$((i + 1))
    off=$((start * 512))
    echo
    echo "## partition $i (offset $off)"
    debugfs -R stats "$IMG?offset=$off" 2>/dev/null |
        grep -E '^(Filesystem volume name|Filesystem UUID|Filesystem features|Block count|Block size|Free blocks|Inode count|Free inodes|Inode size|Filesystem revision)' || true
    lab=$(debugfs -R stats "$IMG?offset=$off" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')
    if [[ $lab == tsv-boot ]]; then
        echo
        echo "### files"
        debugfs -R "ls -l /" "$IMG?offset=$off" 2>/dev/null | awk 'NF>=8 && $NF !~ /^\./ {print $NF, $(NF-3)}'
        debugfs -R "ls -l /dtbs/qcom" "$IMG?offset=$off" 2>/dev/null | awk 'NF>=8 && $NF !~ /^\./ {print "dtbs/qcom/"$NF, $(NF-3)}'
        echo
        echo "### /extlinux/extlinux.conf"
        debugfs -R "cat /extlinux/extlinux.conf" "$IMG?offset=$off" 2>/dev/null
        echo
        echo "### inode flags of the files lk2nd loads (0x80000 = extents; must be absent)"
        for f in /extlinux/extlinux.conf /Image.gz /initramfs-tsv.img /dtbs/qcom/apq8053-lenovo-cd-18781y.dtb; do
            echo "$f: $(debugfs -R "stat $f" "$IMG?offset=$off" 2>/dev/null | sed -n 's/.*Flags: \(0x[0-9a-f]*\).*/flags \1/p')"
        done
    fi
    if [[ $lab == tsv-root ]]; then
        echo
        echo "### adb (mode uid gid type path)"
        for f in /opt/adbd/bin/adbd /opt/adbd/libexec/adbd-reboot /opt/adbd/lib/libbase.so.0 \
            /opt/adbd/lib/libcutils.so.0 /opt/adbd/lib/liblog.so.0 /opt/adbd/lib/libcrypto.so.0 \
            /opt/adbd/lib/libssl.so.0 /opt/adbd/lib/libprotobuf.so.32 /etc/adbd/adb_keys \
            /etc/systemd/system/tsv-adbd.service /etc/systemd/system/sysinit.target.wants/tsv-adbd.service \
            /etc/systemd/system/tsv-usb-gadget.service /usr/local/sbin/tsv-usb-gadget; do
            debugfs -R "stat $f" "$IMG?offset=$off" 2>/dev/null |
                awk -v f="$f" '/^Inode:/{for (i = 1; i < NF; i++) if ($i == "Mode:") m = $(i + 1); t = $4} /^User:/{u = $2; g = $4} END{if (m) print m, u, g, t, f; else print "MISSING", f}'
        done
        echo
        echo "### boot splash and idle screen (mode uid gid type path)"
        for f in /etc/plymouth/plymouthd.conf /usr/share/plymouth/themes/aiand/aiand.plymouth \
            /usr/share/plymouth/themes/aiand/aiand.script /usr/share/plymouth/themes/aiand/logo.png \
            /usr/share/plymouth/themes/aiand/bar.png /usr/bin/plymouthd \
            /etc/systemd/system/tsv-idle-screen.service /usr/local/sbin/tsv-idle-screen \
            /etc/udev/rules.d/90-tsv-idle-screen.rules /etc/tsv/idle-screen.conf \
            /usr/share/tsv/idle-screen/idle-800x1280.xrgb8888.zst /usr/share/tsv/idle-screen/idle-800x1280.rgb565.zst; do
            debugfs -R "stat $f" "$IMG?offset=$off" 2>/dev/null |
                awk -v f="$f" '/^Inode:/{for (i = 1; i < NF; i++) if ($i == "Mode:") m = $(i + 1); t = $4} /^User:/{u = $2; g = $4} END{if (m) print m, u, g, t, f; else print "MISSING", f}'
        done
        echo "plymouthd.conf: $(debugfs -R "cat /etc/plymouth/plymouthd.conf" "$IMG?offset=$off" 2>/dev/null | grep '^Theme=')"
        echo "adb_keys: $(debugfs -R "cat /etc/adbd/adb_keys" "$IMG?offset=$off" 2>/dev/null | sha256sum | cut -c1-16)… (sha256 prefix)"
    fi
done < <(sfdisk -d "$IMG" | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\).*/\1 \2/p')
