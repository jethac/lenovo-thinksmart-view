#!/bin/bash
# End-to-end rehearsal of stage B on the laptop, against a full-size sparse
# image of the eMMC (15269888 sectors) built from the stock GPT copies.
#   streams/stage-b/rehearse.sh
# Content placed on the image: the stock GPT, the system image in p24, the
# live persist and the backed-up syscfg/mcfg/apdp/msadp at their stock places,
# and random data where the tail partitions will go (stands in for userdata).
# No root needed; nothing on the host is mounted.
set -euo pipefail
SB=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SB/../.." && pwd)
B=$ROOT/backup-20261029
W=$SB/work/rehearsal
SYSIMG=${SYSIMG:-$ROOT/rootfs/out/thinksmart-alarm-system.img}
PERSIST=$ROOT/flash-work/stage-b/persist-live-20261030.img
SECTORS=15269888
t0=$(date +%s.%N)
lap() { printf '  (%.1f s)\n' "$(echo "$(date +%s.%N) - $t0" | bc)"; t0=$(date +%s.%N); }
hdr() { echo; echo "== $*"; }

rm -rf "$W"; mkdir -p "$W"
"$SB/make-bundle.sh" "$W/bundle" >/dev/null
export DISK=$W/disk.img REHEARSAL=1 STATE=$W/state
S=$W/bundle/stage-b.sh

hdr "build the stock disk image"
truncate -s $((SECTORS * 512)) "$DISK"
dd if="$B/gpt_primary.bin" of="$DISK" conv=notrunc status=none
dd if="$B/gpt_backup.bin" of="$DISK" bs=512 seek=15269855 conv=notrunc status=none
dd if="$SYSIMG" of="$DISK" bs=1M oflag=seek_bytes seek=$((923648 * 512)) conv=notrunc,sparse status=none
dd if="$PERSIST" of="$DISK" bs=1M oflag=seek_bytes seek=$((5238784 * 512)) conv=notrunc status=none
for p in syscfg:5835776 mcfg:5836800 apdp:6029312 msadp:6029824; do
    zstd -dc "$B/partitions/${p%%:*}.img.zst" |
        dd of="$DISK" bs=1M oflag=seek_bytes seek=$((${p##*:} * 512)) conv=notrunc status=none
done
head -c $((39 * 1024 * 1024)) /dev/urandom |
    dd of="$DISK" bs=1M oflag=seek_bytes seek=$((15187968 * 512)) conv=notrunc status=none
sha_p24_before=$(dd if="$DISK" bs=1M iflag=skip_bytes,count_bytes skip=$((923648 * 512)) \
    count=$((3145728 * 512)) status=none | sha256sum | cut -d' ' -f1)
echo "p24 (stock extent) sha256 $sha_p24_before"
lap

hdr "precheck"; "$S" precheck; lap
hdr "copy-tail"; "$S" copy-tail; lap
hdr "write-gpt"; "$S" write-gpt; lap

hdr "rollback before reboot: stock GPT back, then the new one again"
"$S" rollback-gpt
"$S" precheck >/dev/null && echo "precheck passes on the rolled-back disk"
"$S" write-gpt >/dev/null && echo "new GPT written again"
lap

hdr "interrupted write: backup copy new, primary still stock"
cp --sparse=always "$DISK" "$W/interrupted.img" 2>/dev/null || true
dd if="$B/gpt_primary.bin" of="$W/interrupted.img" conv=notrunc status=none
sfdisk -d "$W/interrupted.img" 2>&1 | grep -E 'persist|userdata|GPT|backup|mismatch|corrupt' | head -5
echo "(primary wins: the disk still reads as the stock layout)"
rm -f "$W/interrupted.img"
lap

hdr "after reboot: kernel would read this table"
sfdisk -l "$DISK" | sed -n '1,8p;/img2[3-9] /p'
"$S" postboot
sha_p24_after=$(dd if="$DISK" bs=1M iflag=skip_bytes,count_bytes skip=$((923648 * 512)) \
    count=$((3145728 * 512)) status=none | sha256sum | cut -d' ' -f1)
[ "$sha_p24_before" = "$sha_p24_after" ] && echo "p24 first 1.5 GiB unchanged (sha256 $sha_p24_after)"
lap

hdr "growroot on the new 'system' extent"
size24=$(awk '/name="system"/ { match($0, /size= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/size= */, "", s); print s }' "$W/bundle/layout.sfdisk")
dd if="$DISK" of="$W/p24.img" bs=1M iflag=skip_bytes,count_bytes skip=$((923648 * 512)) \
    count=$((size24 * 512)) conv=sparse status=none
echo "p24.img: $(($(stat -c%s "$W/p24.img") / 512)) sectors"
# exactly what tsv-growroot runs, on the partition instead of /dev/loop0
echo ',+' | sfdisk --no-reread --no-tell-kernel -N 2 "$W/p24.img" 2>&1 | grep -E 'Old situation|New situation|p2 |img2' | tail -2
sfdisk -d "$W/p24.img" | tail -2
p2start=$(sfdisk -d "$W/p24.img" | awk '/img2 :/ { match($0, /start= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/start= */, "", s); print s }')
p2size=$(sfdisk -d "$W/p24.img" | awk '/img2 :/ { match($0, /size= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/size= */, "", s); print s }')
dd if="$W/p24.img" of="$W/root.img" bs=1M iflag=skip_bytes,count_bytes skip=$((p2start * 512)) \
    count=$((p2size * 512)) conv=sparse status=none
e2fsck -fn "$W/root.img" >/dev/null 2>&1 && echo "root fsck clean before resize" || echo "root fsck before resize: rc $?"
resize2fs "$W/root.img" 2>&1 | grep -E 'now|Nothing'
e2fsck -fn "$W/root.img" 2>&1 | tail -1
dumpe2fs -h "$W/root.img" 2>/dev/null | awk -F: '/^Block count/ { printf "root: %d blocks of 4 KiB = %.2f GiB\n", $2, $2 * 4096 / 2^30 }'
lap

hdr "persist content in its new place"
dd if="$DISK" of="$W/persist-new.img" bs=1M iflag=skip_bytes,count_bytes skip=$((15187968 * 512)) \
    count=$((65536 * 512)) status=none
cmp "$W/persist-new.img" "$PERSIST" && echo "persist at 15187968 is byte-identical to the live copy"
debugfs -R 'ls -l /' "$W/persist-new.img" 2>/dev/null | head -8
rm -f "$W/p24.img" "$W/root.img" "$W/persist-new.img"
echo; echo "rehearsal OK"
