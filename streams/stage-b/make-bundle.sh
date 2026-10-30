#!/bin/bash
# Build the stage-B bundle (what goes onto the tablet) on the laptop.
#   streams/stage-b/make-bundle.sh [OUTDIR]     default: streams/stage-b/work/bundle
# Contents: stage-b.sh, layout.sfdisk, stock_layout.sfdisk, gpt/{stock,new}-{primary,backup}.bin,
# tail.sha256 (expected contents of the five moved partitions), SHA256SUMS.bundle.
# The bundle holds GPT copies of this unit, so it stays out of the repository (work/ is ignored).
set -euo pipefail
SB=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SB/../.." && pwd)
B=$ROOT/backup-20261029
OUT=${1:-$SB/work/bundle}
SECTORS=15269888

# Expected persist: the live partition as read on 2026-10-30, not the backup image.
# The backup was taken while Android had persist mounted (journal not yet replayed);
# Android's clean unmount afterwards changed 232 bytes of metadata and journal.
# File contents are identical (see NOTES.md). Copy kept in flash-work/stage-b/.
PERSIST_LIVE=19c5dd291cc4fb3b9ad90f3923b5bde227c9eb60d03c3e4e8547a3f80bfd6ce2

rm -rf "$OUT"; mkdir -p "$OUT/gpt"
cp "$SB/stage-b.sh" "$OUT/"
cp "$SB/layout.sfdisk" "$OUT/"
sed -E 's#^/dev/mmcblk0([0-9]+) :#/dev/mmcblk0p\1 :#' "$B/stock_layout.sfdisk" > "$OUT/stock_layout.sfdisk"
cp "$B/gpt_primary.bin" "$OUT/gpt/stock-primary.bin"
cp "$B/gpt_backup.bin" "$OUT/gpt/stock-backup.bin"

python3 -I "$SB/make-gpt-blobs.py" --selftest "$B/gpt_primary.bin" "$B/gpt_backup.bin"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
truncate -s $((SECTORS * 512)) "$t/disk.img"
sfdisk -q --no-reread --no-tell-kernel "$t/disk.img" < "$SB/layout.sfdisk"
sfdisk --verify "$t/disk.img" >/dev/null
python3 -I "$SB/make-gpt-blobs.py" --pmbr "$B/gpt_primary.bin" "$t/disk.img" "$t/blobs" >/dev/null
cp "$t/blobs/primary.bin" "$OUT/gpt/new-primary.bin"
cp "$t/blobs/backup.bin" "$OUT/gpt/new-backup.bin"

{
    echo "$PERSIST_LIVE persist"
    for n in syscfg mcfg apdp msadp; do
        echo "$(awk -v f="$n.img" '$2 == f { print $1 }' "$B/partitions/SHA256SUMS.device") $n"
    done
} > "$OUT/tail.sha256"
(cd "$OUT" && sha256sum stage-b.sh layout.sfdisk stock_layout.sfdisk gpt/*.bin tail.sha256 > SHA256SUMS.bundle)
chmod +x "$OUT/stage-b.sh"
echo "bundle: $OUT"
cat "$OUT/SHA256SUMS.bundle"
