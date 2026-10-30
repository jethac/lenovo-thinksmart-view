#!/bin/bash
# Stage B repartitioning of the ThinkSmart View eMMC, from the running system.
#
# The new GPT keeps p1-p23 and the start of p24 'system' (which holds the
# running image, mapped by tsv-subpart through /dev/loop0), grows 'system',
# and moves persist, syscfg, mcfg, apdp and msadp to the end of the disk.
# Nothing inside p1-p23 or p24 is written. The only writes are:
#   - the five tail partitions, copied to their new places (inside what is
#     'userdata' in the stock table, unused by Linux);
#   - the two GPT copies, as pre-built blobs (LBA 0-33 and LBA 15269855-15269887).
# The kernel's view of the partitions is left alone (no re-read), so the
# running system keeps working until the reboot.
#
# Usage: stage-b.sh <step>      run from the bundle directory, as root
#   precheck       read-only: disk, kernel view, GPT on disk, bundle, tail hashes
#   copy-tail      copy the five tail partitions to their new places, verify
#   write-gpt      write the new GPT (backup copy first, then primary), verify
#   verify-gpt     read-only: on-disk GPT equals the new blobs and layout.sfdisk
#   rollback-gpt   write the stock GPT back (backup first, then primary), verify
#   postboot       read-only, after the reboot: kernel view and tail contents
#   grow           remove the growroot marker and run tsv-growroot
#
# Environment (rehearsal on a disk image file on the laptop):
#   DISK=<file>  REHEARSAL=1  (skips the checks that need the live kernel)
set -euo pipefail

DISK=${DISK:-/dev/mmcblk0}
REHEARSAL=${REHEARSAL:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
STATE=${STATE:-$HERE/state}
SECTORS=15269888            # 7.28 GiB, /sys/block/mmcblk0/size
BACKUP_LBA=15269855         # last-lba + 1: start of the backup entry area
TAIL="persist syscfg mcfg apdp msadp"

log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
mkdir -p "$STATE"

# start/size of a partition by name in an sfdisk dump
field() { # file name start|size
    awk -v n="\"$2\"" -v f="$3" '
        index($0, "name=" n) {
            if (match($0, " " f "= *[0-9]+")) {
                v = substr($0, RSTART, RLENGTH); sub(/^.*= */, "", v); print v; exit } }' "$1"
}
expected() { awk -v n="$1" '$2 == n { print $1 }' "$HERE/tail.sha256"; }

# hash N sectors of the disk starting at LBA S, bypassing the page cache
hash_range() { # start size
    dd if="$DISK" iflag=direct,skip_bytes,count_bytes bs=1M \
        skip=$(($1 * 512)) count=$(($2 * 512)) status=none | sha256sum | cut -d' ' -f1
}
read_range() { # start size outfile
    dd if="$DISK" iflag=direct,skip_bytes,count_bytes bs=1M \
        skip=$(($1 * 512)) count=$(($2 * 512)) of="$3" status=none
}
write_file() { # file start-lba
    dd if="$1" of="$DISK" oflag=direct,seek_bytes,sync conv=notrunc,fsync bs=1M \
        seek=$(($2 * 512)) status=none
}
dump_norm() { # sfdisk dump -> comparable form (no device names)
    sed -E 's#^\S+ :#P :#; /^device:/d' "$1" | sed -E 's/ +/ /g'
}

gpt_matches() { # primary backup  -> 0 if the disk carries exactly these
    local t; t=$(mktemp -d)
    read_range 0 34 "$t/p"; read_range "$BACKUP_LBA" 33 "$t/b"
    local rc=0
    cmp -s "$t/p" "$1" || rc=1
    cmp -s "$t/b" "$2" || rc=1
    rm -rf "$t"; return $rc
}

check_bundle() {
    (cd "$HERE" && sha256sum --quiet -c SHA256SUMS.bundle) || die "bundle checksum mismatch"
    local n os ns ss
    for n in $TAIL; do
        os=$(field "$HERE/stock_layout.sfdisk" "$n" size)
        ns=$(field "$HERE/layout.sfdisk" "$n" size)
        [ -n "$os" ] && [ "$os" = "$ns" ] || die "$n: stock size $os, new size $ns"
        [ -n "$(expected "$n")" ] || die "$n: no expected hash in tail.sha256"
    done
    [ "$(field "$HERE/layout.sfdisk" system start)" = 923648 ] || die "system start moved"
}

check_kernel_view() {
    [ "$REHEARSAL" = 1 ] && { log "rehearsal: kernel checks skipped"; return 0; }
    [ "$(cat /sys/block/mmcblk0/size)" = "$SECTORS" ] || die "disk size"
    [ "$(cat /sys/class/block/mmcblk0p24/start)" = 923648 ] || die "kernel p24 start"
    [ "$(cat /sys/class/block/mmcblk0p24/uevent | sed -n 's/^PARTNAME=//p')" = system ] || die "p24 not system"
    local src back
    src=$(findmnt -no SOURCE /)
    back=$(losetup -nO BACK-FILE "/dev/$(basename "$(readlink -f "/sys/class/block/$(basename "$src")/..")")")
    [ "$back" = /dev/mmcblk0p24 ] || die "root $src is not on mmcblk0p24 (backed by $back)"
    log "kernel: root $src on loop over $back, p24 start 923648"
}

step_precheck() {
    check_bundle
    [ "$(($(blockdev --getsz "$DISK" 2>/dev/null || echo $(($(stat -c%s "$DISK") / 512)))))" = "$SECTORS" ] \
        || die "$DISK is not $SECTORS sectors"
    check_kernel_view
    if gpt_matches "$HERE/gpt/stock-primary.bin" "$HERE/gpt/stock-backup.bin"; then
        log "GPT on disk: stock (byte-identical to backup-20261029)"
    elif gpt_matches "$HERE/gpt/new-primary.bin" "$HERE/gpt/new-backup.bin"; then
        log "GPT on disk: already the new layout"
    else
        die "GPT on disk is neither stock nor new"
    fi
    sfdisk --verify "$DISK" >/dev/null || die "sfdisk --verify"
    local n st sz h
    for n in $TAIL; do
        st=$(field "$HERE/stock_layout.sfdisk" "$n" start); sz=$(field "$HERE/stock_layout.sfdisk" "$n" size)
        h=$(hash_range "$st" "$sz")
        [ "$h" = "$(expected "$n")" ] || die "$n at $st: $h, expected $(expected "$n")"
        log "$n at stock place $st (+$sz): sha256 OK"
    done
    touch "$STATE/precheck.ok"
}

step_copy_tail() {
    [ -e "$STATE/precheck.ok" ] || die "run precheck first"
    local n os ns sz h t
    t=$(mktemp -d)
    for n in $TAIL; do
        os=$(field "$HERE/stock_layout.sfdisk" "$n" start)
        ns=$(field "$HERE/layout.sfdisk" "$n" start)
        sz=$(field "$HERE/layout.sfdisk" "$n" size)
        read_range "$os" "$sz" "$t/$n.img"
        h=$(sha256sum "$t/$n.img" | cut -d' ' -f1)
        [ "$h" = "$(expected "$n")" ] || die "$n: source changed ($h)"
        write_file "$t/$n.img" "$ns"
        h=$(hash_range "$ns" "$sz")
        [ "$h" = "$(expected "$n")" ] || die "$n at $ns: read back $h"
        log "$n copied $os -> $ns (+$sz), read back sha256 OK"
    done
    rm -rf "$t"
    sync
    touch "$STATE/copy-tail.ok"
}

step_verify_gpt() {
    gpt_matches "$HERE/gpt/new-primary.bin" "$HERE/gpt/new-backup.bin" \
        || die "on-disk GPT is not the new blobs"
    sfdisk --verify "$DISK" >/dev/null || die "sfdisk --verify"
    local t; t=$(mktemp)
    sfdisk -d "$DISK" > "$t"
    diff <(dump_norm "$HERE/layout.sfdisk") <(dump_norm "$t") || die "sfdisk -d differs from layout.sfdisk"
    rm -f "$t"
    log "GPT on disk: new layout, both copies byte-identical, matches layout.sfdisk"
}

step_write_gpt() {
    [ -e "$STATE/copy-tail.ok" ] || die "run copy-tail first"
    gpt_matches "$HERE/gpt/stock-primary.bin" "$HERE/gpt/stock-backup.bin" || die "GPT on disk is not stock"
    check_kernel_view
    log "writing backup GPT at LBA $BACKUP_LBA"
    write_file "$HERE/gpt/new-backup.bin" "$BACKUP_LBA"
    log "writing primary GPT at LBA 0  (from here the next boot uses the new layout)"
    write_file "$HERE/gpt/new-primary.bin" 0
    sync
    step_verify_gpt
    touch "$STATE/write-gpt.ok"
}

step_rollback_gpt() {
    log "writing stock backup GPT at LBA $BACKUP_LBA"
    write_file "$HERE/gpt/stock-backup.bin" "$BACKUP_LBA"
    log "writing stock primary GPT at LBA 0"
    write_file "$HERE/gpt/stock-primary.bin" 0
    sync
    gpt_matches "$HERE/gpt/stock-primary.bin" "$HERE/gpt/stock-backup.bin" || die "stock GPT read back differs"
    local t; t=$(mktemp)
    sfdisk -d "$DISK" > "$t"
    diff <(dump_norm "$HERE/stock_layout.sfdisk") <(dump_norm "$t") || die "sfdisk -d differs from stock"
    rm -f "$t"
    rm -f "$STATE/write-gpt.ok"
    log "GPT on disk: stock again, byte-identical to backup-20261029"
}

step_postboot() {
    step_verify_gpt
    if [ "$REHEARSAL" != 1 ]; then
        [ "$(cat /sys/class/block/mmcblk0p24/size)" = "$(field "$HERE/layout.sfdisk" system size)" ] \
            || die "kernel p24 size is not the new size (rebooted?)"
        [ ! -e /sys/class/block/mmcblk0p30 ] || die "kernel still sees p30+"
        local loop; loop=$(losetup -j /dev/mmcblk0p24 | cut -d: -f1)
        [ "$(blockdev --getsz "$loop")" = "$(field "$HERE/layout.sfdisk" system size)" ] || die "$loop size"
        log "kernel: 29 partitions, p24 and $loop at the new size"
    fi
    local n ns sz h dev
    for n in $TAIL; do
        ns=$(field "$HERE/layout.sfdisk" "$n" start); sz=$(field "$HERE/layout.sfdisk" "$n" size)
        if [ "$REHEARSAL" = 1 ]; then
            h=$(hash_range "$ns" "$sz")
        else
            dev=$(readlink -f "/dev/disk/by-partlabel/$n")
            [ "$(cat "/sys/class/block/$(basename "$dev")/start")" = "$ns" ] || die "$n: $dev not at $ns"
            h=$(dd if="$dev" iflag=direct bs=1M status=none | sha256sum | cut -d' ' -f1)
        fi
        [ "$h" = "$(expected "$n")" ] || die "$n: $h"
        log "$n at $ns: sha256 OK"
    done
}

step_grow() {
    [ "$REHEARSAL" = 1 ] && die "grow is rehearsed by rehearse.sh on a carved copy"
    step_postboot
    log "point of no return: root grows past the stock end of 'system'"
    rm -f /var/lib/tsv/growroot.done
    systemctl start tsv-growroot.service
    journalctl -u tsv-growroot -b 0 --no-pager | tail -6
    df -h /
}

case "${1:-}" in
    precheck) step_precheck ;;
    copy-tail) step_copy_tail ;;
    write-gpt) step_write_gpt ;;
    verify-gpt) step_verify_gpt ;;
    rollback-gpt) step_rollback_gpt ;;
    postboot) step_postboot ;;
    grow) step_grow ;;
    *) sed -n '2,25p' "$0"; exit 2 ;;
esac
