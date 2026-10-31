#!/bin/bash
# Rehearse install/install.sh without a device: a full-size image of this unit's eMMC, built
# from backup-20261029, stands in for the tablet, and install/mock-edl.py stands in for edl
# (rs/ws/printgpt/reset on the image file). Nothing here talks to USB.
#   install/rehearse.sh            all scenarios; log in install/work/rehearsal/rehearsal.log
# Needs about 12 GiB free under install/work (sparse images and reflink copies on btrfs).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
B=$ROOT/backup-20261029
SB=$ROOT/streams/stage-b
W=$HERE/work/rehearsal
IMG=${IMG:-$ROOT/rootfs/out/thinksmart-alarm-system.img}
LK2ND=${LK2ND:-$ROOT/lk2nd/out/lk2nd.img}
SECTORS=15269888
SERIAL=HUA0BMNX
export TSV_TMPDIR=$W/tmp TMPDIR=$W/tmp
export TSV_SKIP_USB_CHECK=1
export TSV_EDL="python3 -I $HERE/mock-edl.py"
TSV="python3 -I $HERE/tsvgpt.py"

rm -rf "$W"; mkdir -p "$W/tmp"
exec > >(tee "$W/rehearsal.log") 2>&1
T0=$(date +%s)
hdr() { echo; echo "== $*"; }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
lap() { echo "   ($(($(date +%s) - T0)) s so far)"; }
sha_range() { dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip=$(($2 * 512)) count=$(($3 * 512)) status=none | sha256sum | cut -d' ' -f1; }
disk_sha() { sha256sum "$1" | cut -d' ' -f1; }

# run the installer against a disk image; extra args after the image name
# INPUT is what gets typed when the installer asks for the serial number
run() { # name disk units input args...
    local name=$1 disk=$2 units=$3 input=$4 st=$W/state-${RUNSTATE:-$1}; shift 4
    mkdir -p "$st"
    set +e
    printf '%s\n' "$input" | MOCK_EDL_DISK=$disk MOCK_EDL_STATE=$st \
        "$HERE/install.sh" --units "$units" --image "$IMG" --lk2nd "$LK2ND" "$@" > "$W/$name.log" 2>&1
    RC=$?
    set -e
    echo "   install.sh $* -> rc $RC ($(grep -c '' "$W/$name.log") lines, $W/$name.log)"
}
ops() { grep -c -E "^$2( |$)" "$W/state-$1/ops.log" 2> /dev/null || true; }
# resume cases keep one mock session: the unit stays in EDL with the programmer running

hdr "build the stock eMMC image of $SERIAL from backup-20261029"
D0=$W/stock.img
truncate -s $((SECTORS * 512)) "$D0"
dd if="$B/gpt_primary.bin" of="$D0" conv=notrunc status=none
dd if="$B/gpt_backup.bin" of="$D0" bs=512 seek=$((SECTORS - 33)) conv=notrunc status=none
n=0
while IFS=$'\t' read -r num name start size rest; do
    [ "$name" = userdata ] && continue
    zstd -dc -q "$B/partitions/$name.img.zst" |
        dd of="$D0" bs=1M oflag=seek_bytes seek=$((start * 512)) conv=notrunc,sparse status=none
    n=$((n + 1))
done < <($TSV table "$B/gpt_primary.bin")
# Android data where userdata starts and where the stage-B tail will go
head -c $((64 << 20)) /dev/urandom | dd of="$D0" bs=1M oflag=seek_bytes seek=$((6890512 * 512)) conv=notrunc status=none
head -c $((78336 * 512)) /dev/urandom | dd of="$D0" bs=1M oflag=seek_bytes seek=$((15187968 * 512)) conv=notrunc status=none
echo "   $n partitions placed at their stock offsets, GPT copies at LBA 0 and $((SECTORS - 33)); $(du -h "$D0" | cut -f1) allocated"
STOCK_LOW=$(sha_range "$D0" 0 6890512)
STOCK_SHA=$(disk_sha "$D0")
lap

hdr "refusals (nothing may be written)"
D=$W/neg.img; cp --reflink=always "$D0" "$D"
MOCK_EDL_HWID=0x000560e100000000 run neg-hwid "$D" "$W/units-neg" "$SERIAL"
grep -q 'STOP: HWID' "$W/neg-hwid.log" && [ "$RC" != 0 ] && pass "other HWID refused: $(grep -o 'STOP: .*' "$W/neg-hwid.log")" || fail "other HWID refused: $(grep -o 'STOP: .*' "$W/neg-hwid.log")"
MOCK_EDL_PKHASH=0x1234 run neg-pk "$D" "$W/units-neg" "$SERIAL"
grep -q 'STOP: PK hash' "$W/neg-pk.log" && pass "other PK hash refused" || fail "other PK hash refused"
run neg-serial "$D" "$W/units-neg" "HUA0XXXX"
grep -q 'STOP: confirmation does not match' "$W/neg-serial.log" && [ "$(ops neg-serial ws)" = 0 ] && pass "wrong serial typed: stopped before any write" || fail "wrong serial typed: stopped before any write"
D2=$W/neg-unknown.img; cp --reflink=always "$D0" "$D2"
echo 'label: gpt
,1M' | sfdisk -q --no-reread --no-tell-kernel "$D2" > /dev/null 2>&1
run neg-unknown "$D2" "$W/units-neg" "$SERIAL"
grep -q 'STOP: partition table is neither stock nor stage-B' "$W/neg-unknown.log" && pass "foreign GPT refused: $(grep -o 'unit HUA0BMNX: .*' "$W/neg-unknown.log" | head -1)" || fail "foreign GPT refused: $(grep -o 'unit HUA0BMNX: .*' "$W/neg-unknown.log" | head -1)"
rm -f "$D2"
[ "$(disk_sha "$D")" = "$STOCK_SHA" ] && pass "disk image unchanged by the refused runs" || fail "disk image unchanged by the refused runs"
[ ! -e "$W/units-neg/$SERIAL-$(date +%Y%m%d)" ] && pass "no unit folder created by refused runs" || fail "no unit folder created by refused runs"
rm -f "$D"
lap

hdr "dry run on the stock image"
D=$W/dry.img; cp --reflink=always "$D0" "$D"
run dry "$D" "$W/units-dry" "" --dry-run
[ "$RC" = 0 ] || fail "dry run rc $RC"
sed -n '/^PLAN for/,/dry run:/p' "$W/dry.log" | sed 's/^\[[0-9:]*\] //'
[ "$(ops dry ws)" = 0 ] && [ "$(disk_sha "$D")" = "$STOCK_SHA" ] && pass "dry run: no write reached the disk ($(ops dry rs) reads of GPT and devinfo only)" || fail "dry run: no write reached the disk ($(ops dry rs) reads of GPT and devinfo only)"
rm -f "$D"
lap

hdr "1. stock -> installed"
D1=$W/disk1.img; cp --reflink=always "$D0" "$D1"
U1=$W/units-1
run s1 "$D1" "$U1" "$SERIAL" --no-wait
[ "$RC" = 0 ] || { tail -20 "$W/s1.log"; fail "install rc $RC"; }
UD1=$(ls -1d "$U1/$SERIAL"-* | head -1)
grep -v '^  READ' "$W/s1.log" | grep -E 'identity:|unit HUA0BMNX|selftest|uuids-kept|verify-backup|tail partitions: read back|GPT: stage-B|system image: read back|lk2nd: read back|EDL part done' | sed 's/^\[[0-9:]*\] /   /'
cmp -s "$UD1/gpt-new/primary.bin" "$ROOT/flash-work/stage-b/new-primary.bin" && cmp -s "$UD1/gpt-new/backup.bin" "$ROOT/flash-work/stage-b/new-backup.bin" \
    && pass "this unit's generated GPT is byte-identical to the blobs that booted on $SERIAL (flash-work/stage-b/new-*.bin)" || fail "this unit's generated GPT is byte-identical to the blobs that booted on $SERIAL (flash-work/stage-b/new-*.bin)"
diff <(sed -E 's#^\S+ :#P :#; /^device:/d; s/ +/ /g' "$UD1/gpt-new/layout.sfdisk") <(sed -E 's#^\S+ :#P :#; /^device:/d; s/ +/ /g' "$SB/layout.sfdisk") > /dev/null \
    && pass "generated layout.sfdisk equals streams/stage-b/layout.sfdisk" || fail "generated layout.sfdisk equals streams/stage-b/layout.sfdisk"
# the installer's backup against the 2026-10-29 backup, partition by partition
bad=0; cnt=0
while read -r h f; do
    case "$f" in partitions/*) ;; *) continue ;; esac
    p=$(basename "$f"); cnt=$((cnt + 1))
    [ "$h" = "$(awk -v f="$p" '$2 == f { print $1 }' "$B/partitions/SHA256SUMS.device")" ] || { echo "   differs: $p"; bad=1; }
done < "$UD1/SHA256SUMS"
[ "$bad" = 0 ] && pass "installer backup: $cnt partitions, each sha256 equal to backup-20261029/partitions/SHA256SUMS.device" || fail "installer backup: $cnt partitions, each sha256 equal to backup-20261029/partitions/SHA256SUMS.device"
cmp -s "$UD1/gpt/primary.bin" "$B/gpt_primary.bin" && cmp -s "$UD1/gpt/backup.bin" "$B/gpt_backup.bin" && pass "installer backup: GPT copies equal backup-20261029" || fail "installer backup: GPT copies equal backup-20261029"
echo "   backup folder: $(du -sh "$UD1" | cut -f1) on disk, $(ls "$UD1/partitions" | wc -l) partition images, $(wc -l < "$UD1/gaps.tsv") gaps ($(grep -c data "$UD1/gaps.tsv" || true) non-zero)"
S1_SHA=$(disk_sha "$D1")
lap

hdr "1a. check the installed disk"
sfdisk --verify "$D1" > /dev/null 2>&1 && pass "sfdisk --verify clean" || fail "sfdisk --verify clean"
diff <(sfdisk -d "$D1" | sed -E 's#^\S+ :#P :#; /^device:/d; s/ +/ /g') <(sed -E 's#^\S+ :#P :#; /^device:/d; s/ +/ /g' "$SB/layout.sfdisk") \
    && pass "sfdisk -d of the installed disk equals layout.sfdisk (29 partitions)" || fail "sfdisk -d of the installed disk equals layout.sfdisk (29 partitions)"
sfdisk -l "$D1" | sed -n '/img24 /p;/img2[5-9] /p' | sed "s#$W/##; s/^/   /"
for n in persist syscfg mcfg apdp msadp; do
    st=$(awk -v n="\"$n\"" 'index($0, "name=" n) { match($0, /start= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/start= */, "", s); print s }' "$SB/layout.sfdisk")
    sz=$(awk -v n="\"$n\"" 'index($0, "name=" n) { match($0, /size= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/size= */, "", s); print s }' "$SB/layout.sfdisk")
    [ "$(sha_range "$D1" "$st" "$sz")" = "$(awk -v f="$n.img" '$2 == f { print $1 }' "$B/partitions/SHA256SUMS.device")" ] \
        && pass "$n at $st (+$sz) byte-identical to backup-20261029/$n.img" || fail "$n at $st (+$sz) byte-identical to backup-20261029/$n.img"
done
cmp -s <(dd if="$D1" bs=512 skip=923648 count=$(($(stat -c%s "$IMG") / 512)) status=none) "$IMG" && pass "system: the image is at LBA 923648" || fail "system: the image is at LBA 923648"
cmp -s <(dd if="$D1" bs=512 skip=790528 count=$(($(stat -c%s "$LK2ND") / 512 + 1)) status=none | head -c "$(stat -c%s "$LK2ND")") "$LK2ND" && pass "boot: lk2nd at LBA 790528" || fail "boot: lk2nd at LBA 790528"
[ "$(sha_range "$D1" 34 790494)" = "$(sha_range "$D0" 34 790494)" ] && [ "$(sha_range "$D1" 856064 67584)" = "$(sha_range "$D0" 856064 67584)" ] \
    && pass "p1-p20 and p22-p23 (bootloaders, modem, modemst*, fsg, devinfo, recovery) untouched, apart from the GPT" || fail "p1-p20 and p22-p23 (bootloaders, modem, modemst*, fsg, devinfo, recovery) untouched, apart from the GPT"
lap

hdr "1b. first boot, as far as it can be checked offline"
P24=923648; SYS=$(awk '/name="system"/ { match($0, /size= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/size= */, "", s); print s }' "$SB/layout.sfdisk")
dd if="$D1" bs=512 skip=$P24 count=1 status=none > "$W/p24-mbr.bin"
sfdisk -d "$W/p24-mbr.bin" 2> /dev/null | sed -n '/: start/p' | sed "s#$W/##; s/^/   nested MBR: /"
read -r p1s p2s < <(python3 -I -c "
import struct,sys; m=open(sys.argv[1],'rb').read(512); assert m[510:]==b'\x55\xaa'
print(struct.unpack('<I',m[446+8:446+12])[0], struct.unpack('<I',m[462+8:462+12])[0])" "$W/p24-mbr.bin")
BOOTFS="$D1?offset=$(((P24 + p1s) * 512))"; ROOTFS="$D1?offset=$(((P24 + p2s) * 512))"
feat=$(debugfs -R stats "$BOOTFS" 2> /dev/null | sed -n 's/^Filesystem features: *//p')
lab=$(debugfs -R stats "$BOOTFS" 2> /dev/null | sed -n 's/^Filesystem volume name: *//p')
ok=1; for f in $feat; do case "$f" in filetype|sparse_super|large_file|ext_attr|resize_inode|dir_index) ;; *) ok=0 ;; esac; done
[ "$ok" = 1 ] && pass "p24 MBR p1 '$lab' (LBA $((P24 + p1s))) is ext2 lk2nd can read: features '$feat'" || fail "p24 MBR p1 '$lab' (LBA $((P24 + p1s))) is ext2 lk2nd can read: features '$feat'"
debugfs -R "cat /extlinux/extlinux.conf" "$BOOTFS" 2> /dev/null > "$W/extlinux.conf"
sed 's/^/   extlinux: /' "$W/extlinux.conf"
for key in linux kernel initrd fdt devicetree; do
    for f in $(awk -v k="$key" 'tolower($1) == k { print $2 }' "$W/extlinux.conf"); do
        fl=$(debugfs -R "stat $f" "$BOOTFS" 2> /dev/null | sed -n 's/.*Flags: \(0x[0-9a-f]*\).*/\1/p')
        [ "$fl" = 0x0 ] && pass "extlinux $key $f exists, inode flags 0x0 (no extents)" || fail "extlinux $key $f: flags '$fl'" || fail "extlinux $key $f exists, inode flags 0x0 (no extents)" || fail "extlinux $key $f: flags '$fl'"
    done
done
grep -q 'root=LABEL=tsv-root' "$W/extlinux.conf" && grep -q 'tsv_subpart=PARTLABEL=system' "$W/extlinux.conf" && pass "kernel command line: root=LABEL=tsv-root via tsv_subpart=PARTLABEL=system" || fail "kernel command line: root=LABEL=tsv-root via tsv_subpart=PARTLABEL=system"
[ "$(sfdisk -d "$D1" | grep -c 'name="system"')" = 1 ] && pass "exactly one GPT partition is labelled 'system' (p24)" || fail "exactly one GPT partition is labelled 'system' (p24)"
rlab=$(debugfs -R stats "$ROOTFS" 2> /dev/null | sed -n 's/^Filesystem volume name: *//p')
[ "$rlab" = tsv-root ] && pass "p24 MBR p2 (LBA $((P24 + p2s))) is ext4 labelled tsv-root" || fail "p24 MBR p2 (LBA $((P24 + p2s))) is ext4 labelled tsv-root"
for f in /usr/lib/systemd/systemd /usr/local/sbin/tsv-growroot /etc/systemd/system/multi-user.target.wants/tsv-growroot.service; do
    debugfs -R "stat $f" "$ROOTFS" 2> /dev/null | grep -q '^Inode:' && pass "root has $f" || fail "root lacks $f" || fail "root has $f" || fail "root lacks $f"
done
debugfs -R "stat /var/lib/tsv/growroot.done" "$ROOTFS" 2>&1 | grep -q 'File not found' && pass "no growroot.done in the image: tsv-growroot runs on the first boot" || fail "no growroot.done in the image: tsv-growroot runs on the first boot"
# what tsv-growroot does on the first boot, on a copy of p24
dd if="$D1" of="$W/p24.img" bs=1M iflag=skip_bytes,count_bytes skip=$((P24 * 512)) count=$((SYS * 512)) conv=sparse status=none
echo ',+' | sfdisk --no-reread --no-tell-kernel -N 2 "$W/p24.img" > /dev/null 2>&1
read -r gs gn < <(sfdisk -d "$W/p24.img" | awk '/p24.img2 :/ { match($0, /start= *[0-9]+/); s = substr($0, RSTART, RLENGTH); sub(/start= */, "", s); match($0, /size= *[0-9]+/); z = substr($0, RSTART, RLENGTH); sub(/size= */, "", z); print s, z }')
echo "   growroot: MBR p2 -> start $gs size $gn (p24 is $SYS sectors)"
dd if="$W/p24.img" of="$W/root.img" bs=1M iflag=skip_bytes,count_bytes skip=$((gs * 512)) count=$((gn * 512)) conv=sparse status=none
rm -f "$W/p24.img"
e2fsck -fn "$W/root.img" > /dev/null 2>&1 && pass "root e2fsck clean before the grow" || fail "root e2fsck clean before the grow"
resize2fs "$W/root.img" > /dev/null 2>&1
e2fsck -fn "$W/root.img" > /dev/null 2>&1 && pass "root e2fsck clean after the grow" || fail "root e2fsck clean after the grow"
dumpe2fs -h "$W/root.img" 2> /dev/null | awk -F: '/^Block count/ { printf "   root after the grow: %d blocks = %.2f GiB\n", $2, $2 * 4096 / 2^30 }'
rm -f "$W/root.img" "$W/p24-mbr.bin"
lap

hdr "1c. first-boot report logic (adb mocked: proves only the checking code)"
{
    echo "p24=$SYS"; echo nparts=29; echo rootdev=/dev/loop0p2; echo "rootsz=$((SYS - p2s))"; echo growroot=done; echo state=running
    for u in sshd NetworkManager tsv-usb-gadget tsv-usb-dhcp tsv-adbd straylight-voice straylight-listen straylight-aiand straylight-wifi; do echo "unit:$u=active"; done
    echo "failed="
    for n in persist syscfg mcfg apdp msadp; do echo "sha:$n=$(awk -v f="partitions/$n.img" '$2 == f { print $1 }' "$UD1/SHA256SUMS")"; done
    echo "df=6.5G 4.4G"
} > "$W/adb-report.txt"
set +e
MOCK_ADB_REPORT=$W/adb-report.txt TSV_ADB=$HERE/mock-adb.sh "$HERE/install.sh" --units "$U1" --image "$IMG" --check-boot "$UD1" > "$W/s1c.log" 2>&1; rc=$?
set -e
grep -E 'OK|FAIL|first boot' "$W/s1c.log" | sed 's/^\[[0-9:]*\] /   /' | head -20
[ "$rc" = 0 ] && pass "check-boot passes on a report that matches" || fail "check-boot passes on a report that matches"
sed -i 's/^rootsz=.*/rootsz=6027264/' "$W/adb-report.txt"
set +e
MOCK_ADB_REPORT=$W/adb-report.txt TSV_ADB=$HERE/mock-adb.sh "$HERE/install.sh" --units "$U1" --image "$IMG" --check-boot "$UD1" > "$W/s1c2.log" 2>&1; rc=$?
set -e
[ "$rc" != 0 ] && grep -q 'FAIL  root grown' "$W/s1c2.log" && pass "check-boot reports a root that did not grow" || fail "check-boot reports a root that did not grow"
lap

hdr "2. already stage-B -> installed again"
D2=$W/disk2.img; cp --reflink=always "$D1" "$D2"
# a unit that has been running: the system partition no longer holds the fresh image
head -c $((8 << 20)) /dev/urandom | dd of="$D2" bs=1M oflag=seek_bytes seek=$(((923648 + 264192) * 512 + (1 << 30))) conv=notrunc status=none
U2=$W/units-2
run s2 "$D2" "$U2" "$SERIAL" --no-wait
[ "$RC" = 0 ] || { tail -20 "$W/s2.log"; fail "reinstall rc $RC"; }
grep -E "unit HUA0BMNX|already stage-B|GPT backup copy: already|GPT primary copy: already|boot: already|system image: read back|EDL part done" "$W/s2.log" | sed 's/^\[[0-9:]*\] /   /'
[ "$(disk_sha "$D2")" = "$S1_SHA" ] && pass "re-installed disk is byte-identical to the disk from scenario 1" || fail "re-installed disk is byte-identical to the disk from scenario 1"
UD2=$(ls -1d "$U2/$SERIAL"-* | head -1)
grep -q '^ORIGIN=stageb' "$UD2/unit.env" && [ -e "$UD2/partitions/system.img.zst" ] && pass "stage-B backup includes system ($(du -h "$UD2/partitions/system.img.zst" | cut -f1) compressed) and the tail partitions" || fail "stage-B backup includes system ($(du -h "$UD2/partitions/system.img.zst" | cut -f1) compressed) and the tail partitions"
rm -rf "$U2" "$D2"
lap

resume_case() { # name fault description
    local name=$1 fault=$2 desc=$3 D=$W/$1.img U=$W/units-$1
    hdr "$desc"
    cp --reflink=always "$D0" "$D"
    MOCK_EDL_FAIL=$fault RUNSTATE=$name run "$name-a" "$D" "$U" "$SERIAL" --no-wait
    [ "$RC" != 0 ] || fail "the injected fault did not stop the run"
    grep -o 'STOP: .*' "$W/$name-a.log" | sed 's/^/   /'
    dd if="$D" bs=512 count=34 status=none > "$W/p.bin"; dd if="$D" bs=512 skip=$((SECTORS - 33)) count=33 status=none > "$W/b.bin"
    echo "   table on disk now: $($TSV classify "$W/p.bin" "$W/b.bin" $SECTORS | tr '\n' ' ' | sed 's/primary_disk.*//')"
    MOCK_EDL_FAIL=$fault RUNSTATE=$name run "$name-b" "$D" "$U" "$SERIAL" --no-wait
    [ "$RC" = 0 ] || { tail -20 "$W/$name-b.log"; fail "resume rc $RC"; }
    grep -q 'identity: programmer already running' "$W/$name-b.log" && pass "$name: same EDL session, identity taken from the check earlier in the session" || fail "$name: session identity"
    grep -v '^  READ' "$W/$name-b.log" | grep -E 'resuming|reusing|already|unchanged since|tail partitions: read back|GPT: stage-B|system image: read back|lk2nd: read back|EDL part done' | sed 's/^\[[0-9:]*\] /   /'
    [ "$(disk_sha "$D")" = "$S1_SHA" ] && pass "$name: resumed disk is byte-identical to the uninterrupted install" || fail "$name: resumed disk is byte-identical to the uninterrupted install"
    rm -rf "$D" "$U" "$W/p.bin" "$W/b.bin"
    lap
}
resume_case s3 "ws:15269855" "3. interrupted after the tail copy (backup GPT write fails), then resumed"
resume_case s4 "ws:0" "4. interrupted between the two GPT writes (primary write fails), then resumed"
resume_case s5 "ws:0:torn=2" "5. primary GPT write torn after 2 of 34 sectors (new header, old entries), then resumed"
resume_case s6 "ws:923648:torn" "6. system write torn half way, then resumed"

hdr "7. restore the installed disk to stock from the installer's backup"
run s7 "$D1" "$U1" "$SERIAL" --restore "$UD1"
[ "$RC" = 0 ] || { tail -20 "$W/s7.log"; fail "restore rc $RC"; }
grep -E 'RESTORE PLAN|restore:|verify-backup' "$W/s7.log" | sed 's/^\[[0-9:]*\] /   /'
echo "   $(grep -c '^ *WRITE' "$W/s7.log") writes in plan and run"
dd if="$D1" bs=512 count=34 status=none | cmp -s - "$B/gpt_primary.bin" && dd if="$D1" bs=512 skip=$((SECTORS - 33)) count=33 status=none | cmp -s - "$B/gpt_backup.bin" \
    && pass "GPT byte-identical to backup-20261029/gpt_primary.bin and gpt_backup.bin" || fail "GPT byte-identical to backup-20261029/gpt_primary.bin and gpt_backup.bin"
bad=0; cnt=0
while IFS=$'\t' read -r num name start size rest; do
    [ "$name" = userdata ] && continue
    cnt=$((cnt + 1))
    [ "$(sha_range "$D1" "$start" "$size")" = "$(awk -v f="$name.img" '$2 == f { print $1 }' "$B/partitions/SHA256SUMS.device")" ] || { echo "   differs: $name"; bad=1; }
done < <($TSV table "$B/gpt_primary.bin")
[ "$bad" = 0 ] && pass "all $cnt backed-up partitions byte-identical to backup-20261029/partitions (the 28 the install touches included)" || fail "all $cnt backed-up partitions byte-identical to backup-20261029/partitions (the 28 the install touches included)"
[ "$(sha_range "$D1" 0 6890512)" = "$STOCK_LOW" ] && pass "LBA 0-6890511 (everything before userdata, gaps included) byte-identical to the stock image" || fail "LBA 0-6890511 (everything before userdata, gaps included) byte-identical to the stock image"
echo "   (userdata, LBA 6890512 on, is not backed up; the system image and the tail overwrote parts of it)"
run s7b "$D1" "$U1" "$SERIAL" --dry-run
grep -q "partition table 'stock'" "$W/s7b.log" && pass "after the restore the installer sees a stock table again" || fail "after the restore the installer sees a stock table again"
lap

hdr "timing estimate for the real unit (scenario 1 operations, mock op log)"
python3 -I - "$W/state-s1/ops.log" << 'EOF'
import sys
calls = rd = wr = 0
for l in open(sys.argv[1]):
    f = l.split()
    if f[0] in ("rs", "ws"):
        calls += 1
        n = int(f[2]) * 512
        if f[0] == "rs": rd += n
        else: wr += n
    elif f[0] in ("printgpt", "reset"):
        calls += 1
for mbps, per in ((27, 3), (27, 5), (20, 5)):
    t = calls * per + (rd + wr) / (mbps * 1e6)
    print(f"   {calls} edl calls, {rd / 2**30:.2f} GiB read, {wr / 2**30:.2f} GiB written: "
          f"{t / 60:.1f} min at {mbps} MB/s and {per} s per call")
EOF
rm -f "$D1" "$D0"
echo; echo "rehearsal OK ($(($(date +%s) - T0)) s)"
