#!/usr/bin/env bash
# Rebuild the ThinkSmart View (CD-18781Y) Arch Linux ARM image from scratch.
# Rootless: user namespace + qemu-aarch64 binfmt. Nothing is mounted on the
# host, nothing is written to the device backup.
#
#   rootfs/scripts/build-image.sh            full build
#   KEEP_WORK=1 rootfs/scripts/build-image.sh  keep rootfs/work afterwards
#
# Optional: TSV_JETHAC_PASSWORD (hashed with SHA-512 crypt before use; the
# plaintext is never written anywhere). Unset = password login locked.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)                     # rootfs/
PROJ=$(cd "$TOP/.." && pwd)                     # lenovo-8/
DL=$TOP/downloads
WORK=${TSV_WORK:-$TOP/work}                 # overridable for scratch builds
OUT=${TSV_OUT:-$TOP/out}
BACKUP=$PROJ/backup-20261029/partitions
KSRC=$PROJ/kernel/linux-7.3
KBUILD=$PROJ/kernel/build-7.3
PUBKEY=${PUBKEY:-$HOME/.ssh/id_ed25519_stadia_testbed.pub}
ADB_PUBKEY=${ADB_PUBKEY:-$HOME/.android/adbkey.pub}   # becomes /etc/adbd/adb_keys
TARBALL=$DL/ArchLinuxARM-aarch64-latest.tar.gz
IMG=$OUT/thinksmart-alarm-system.img

if [[ ${1:-} == --inner ]]; then
    # ---- inside the user namespace (uid 0 mapped to the invoking user)
    shift
    "$HERE/build-rootfs.sh" "$TARBALL" "$WORK/rootfs" "$WORK/bootfs" "$WORK/firmware" \
        "$KSRC" "$KBUILD" "$PUBKEY" "$WORK/adbd/stage" "$ADB_PUBKEY"
    "$HERE/make-image.sh" "$WORK/rootfs" "$WORK/bootfs" "$WORK" "$IMG"
    exit 0
fi

for t in unshare newuidmap bsdtar mke2fs sfdisk debugfs zstd gpg gpgv curl python3 openssl \
    clang clang++ ld.lld llvm-readelf llvm-strip patchelf qemu-aarch64-static make patch ar xz; do
    command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
[[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] && grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 \
    || { echo "qemu-aarch64 binfmt with the F flag is required" >&2; exit 1; }
[[ -f $KBUILD/arch/arm64/boot/Image.gz ]] || { echo "kernel not built in $KBUILD" >&2; exit 1; }
[[ -f $PUBKEY ]] || { echo "missing $PUBKEY" >&2; exit 1; }
# adb public key: one "<base64 of the 524-byte Android RSA key> [comment]" line.
[[ -f $ADB_PUBKEY && $(wc -l < "$ADB_PUBKEY") -le 1 ]] &&
    [[ $(cut -d' ' -f1 "$ADB_PUBKEY" | base64 -d 2>/dev/null | wc -c) == 524 ]] ||
    { echo "missing or malformed adb public key $ADB_PUBKEY (set ADB_PUBKEY)" >&2; exit 1; }

mkdir -p "$DL" "$WORK" "$OUT"

echo "== 1/5 fetch and verify Arch Linux ARM"
"$HERE/fetch-alarm.sh" "$DL"

echo "== 2/5 fetch, verify and cross-build adbd (Debian android-platform-tools)"
"$HERE/fetch-adbd.sh" "$DL/adbd-debian"
"$HERE/build-adbd.sh" "$DL/adbd-debian" "$WORK/adbd"

echo "== 3/5 extract firmware from the device backup"
"$HERE/extract-firmware.sh" "$BACKUP" "$WORK/partitions" "$WORK/firmware" "$WORK/firmware-manifest.tsv"
# Speaker tuning for the TAS5782M, from Lenovo's GPL source (not the backup)
"$HERE/fetch-tas5782m-tuning.sh" "$DL/lenovo-gpl" "$WORK/firmware" "$WORK/firmware-manifest.tsv"

echo "== 4/5 root filesystem and image (user namespace)"
if [[ -n ${TSV_JETHAC_PASSWORD:-} ]]; then
    TSV_JETHAC_HASH=$(printf '%s' "$TSV_JETHAC_PASSWORD" | openssl passwd -6 -stdin)
    export TSV_JETHAC_HASH
fi
unset TSV_JETHAC_PASSWORD
# If an earlier run was interrupted, its tree is owned by subordinate uids;
# remove it from inside a namespace too.
unshare --user --map-root-user --map-auto --mount --pid --fork \
    rm -rf "$WORK/rootfs" "$WORK/bootfs"
unshare --user --map-root-user --map-auto --mount --pid --fork \
    "$HERE/build-image.sh" --inner
unset TSV_JETHAC_HASH

echo "== 5/5 checksums and listings"
cp "$WORK/firmware-manifest.tsv" "$OUT/firmware-manifest.tsv"
"$HERE/inspect-image.sh" "$IMG" > "$OUT/thinksmart-alarm-system.partitions.txt"
(cd "$OUT" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256")
cat "$OUT/$(basename "$IMG").sha256"

if [[ -z ${KEEP_WORK:-} ]]; then
    unshare --user --map-root-user --map-auto --mount --pid --fork \
        rm -rf "$WORK/rootfs" "$WORK/bootfs" "$WORK/partitions" "$WORK/firmware" "$WORK/adbd"
fi
echo "done: $IMG"
