#!/usr/bin/env bash
# Assemble the 'system' partition image: an MBR with
#   p1  ext2  LABEL=tsv-boot  (lk2nd reads /extlinux/extlinux.conf here)
#   p2  ext4  LABEL=tsv-root
# Filesystems are created from directories with mke2fs -d (no mounting).
# Run inside the build user namespace so file ownership is recorded as root.
#
#   make-image.sh ROOTFS_DIR BOOTFS_DIR WORK_DIR OUT_IMG
# Environment: IMAGE_MIB (default 3072), BOOT_MIB (default 128).
# 3072 MiB holds the voice assistant's fonts and models with room to spare, and
# fits the stage-B 'system' partition (6965 MiB); it no longer fits the stock
# 1536 MiB one. tsv-growroot grows root to the end of the partition on first boot.
set -euo pipefail
R=$1 BOOT=$2 WORK=$3 IMG=$4
IMAGE_MIB=${IMAGE_MIB:-3072}
BOOT_MIB=${BOOT_MIB:-128}
ROOT_MIB=$((IMAGE_MIB - 1 - BOOT_MIB))
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-}
[[ -n $E2FSPROGS_FAKE_TIME ]] || unset E2FSPROGS_FAKE_TIME

mkdir -p "$WORK"
rm -f "$WORK/boot.ext2" "$WORK/root.ext4"

# lk2nd's ext2 driver (lib/fs/ext2, from LK) understands block-mapped ext2
# only: no extents, no 64bit, and it refuses any ro_compat feature other than
# sparse_super and large_file. So: explicit feature list, 4 KiB blocks.
mke2fs -q -F -t ext2 -O none,filetype,sparse_super,large_file -b 4096 -I 256 \
    -L tsv-boot -E root_owner=0:0 -d "$BOOT" "$WORK/boot.ext2" "${BOOT_MIB}M"

mke2fs -q -F -t ext4 -b 4096 -m 2 -L tsv-root -E root_owner=0:0 \
    -d "$R" "$WORK/root.ext4" "${ROOT_MIB}M"

e2fsck -fn "$WORK/boot.ext2" >/dev/null
e2fsck -fn "$WORK/root.ext4" >/dev/null

rm -f "$IMG"
truncate -s "${IMAGE_MIB}M" "$IMG"
sfdisk -q "$IMG" <<SF
label: dos
unit: sectors
start=2048, size=$((BOOT_MIB * 2048)), type=83, bootable
start=$((2048 + BOOT_MIB * 2048)), type=83
SF
dd if="$WORK/boot.ext2" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$WORK/root.ext4" of="$IMG" bs=1M seek=$((1 + BOOT_MIB)) conv=notrunc,sparse status=none
rm -f "$WORK/boot.ext2" "$WORK/root.ext4"
echo "make-image: $IMG (${IMAGE_MIB} MiB, $(du -h "$IMG" | cut -f1) allocated)"
