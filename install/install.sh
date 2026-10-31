#!/bin/bash
# One-session EDL installer for the Lenovo ThinkSmart View (CD-18781Y).
#
# Takes a unit with the stock partition table or the stage-B table (or one left half way by an
# earlier run of this script) and leaves it on the stage-B layout running the Straylight image,
# in a single Qualcomm EDL session. See install/README.md.
#
#   install/install.sh [options]                 install (asks for the serial before writing)
#   install/install.sh --dry-run                 read-only: identify, classify, print the plan
#   install/install.sh --restore units/<dir>     write the backed-up table and partitions back
#   install/install.sh --check-boot units/<dir>  only the first-boot checks, over adb
#
# Options:
#   --image FILE          system image   (default rootfs/out/thinksmart-alarm-system.img)
#   --lk2nd FILE          lk2nd boot image (default lk2nd/out/lk2nd.img)
#   --no-system-backup    do not back up the 'system' partition (saves 1-4 minutes)
#   --fresh-backup        take a new backup even if an unfinished run's backup would fit
#   --no-wait             do not wait for the unit to boot after the reset
#   --reset               with --restore: reset the unit when done
#   --loader FILE         firehose programmer for edl (default: edl's automatic choice)
#   --units DIR           where per-unit backups go (default units/, ignored by git)
#
# Environment: TSV_EDL (edl command, default tools/edl), TSV_ADB (adb command),
# TSV_SKIP_USB_CHECK=1 (do not look for 05c6:9008 on USB; for the rehearsal mock).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SB=$ROOT/streams/stage-b
TSV="python3 -I $HERE/tsvgpt.py"

# This model, as identified by Sahara (FLASHING.md, edl-printgpt.log of 2026-10-30)
HWID_OK=0x000660e160008000
PK_OK=0xb9eca30dfea4693497b6ac7eec81d006967281e259eb9ac239f9ce6dabb70c14
DEVINFO_LBA=921600          # p23 'devinfo', the same in the stock and the stage-B table
SYSTEM_START=923648         # p24 'system' starts here in both tables
TAIL="persist syscfg mcfg apdp msadp"
SERVICES="sshd NetworkManager tsv-usb-gadget tsv-usb-dhcp tsv-adbd straylight-voice straylight-listen straylight-aiand straylight-wifi"
EDL_MBPS=27                 # planning figure, from stage A (FLASHING.md): see README
EDL_CALL_S=5                # planning figure: edl start-up and firehose configure per call

DRY=0; RESTORE=""; CHECK_ONLY=""; NO_SYS_BACKUP=0; FRESH=0; NO_WAIT=0; RESET_AFTER=0; LOADER=""
IMG=$ROOT/rootfs/out/thinksmart-alarm-system.img
LK2ND=$ROOT/lk2nd/out/lk2nd.img
UNITS=$ROOT/units
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --restore) RESTORE=${2:?}; shift ;;
        --check-boot) CHECK_ONLY=${2:?}; shift ;;
        --image) IMG=${2:?}; shift ;;
        --lk2nd) LK2ND=${2:?}; shift ;;
        --no-system-backup) NO_SYS_BACKUP=1 ;;
        --fresh-backup) FRESH=1 ;;
        --no-wait) NO_WAIT=1 ;;
        --reset) RESET_AFTER=1 ;;
        --loader) LOADER=${2:?}; shift ;;
        --units) UNITS=${2:?}; shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

# The laptop's /tmp is small: everything temporary stays under the project.
export TMPDIR=${TSV_TMPDIR:-$ROOT/install/work/tmp}
mkdir -p "$TMPDIR" "$UNITS"
RUN=$(mktemp -d "$TMPDIR/run.XXXXXX")
TS=$(date +%Y%m%d-%H%M%S)
LOG=$RUN/install-$TS.log
EDL_LOG=$RUN/edl-$TS.log
UD=""
cleanup() {
    if [ -z "$UD" ] || [ ! -d "$UD" ]; then
        cp -f "$LOG" "$TMPDIR/last-run.log" 2>/dev/null || true
        cp -f "$EDL_LOG" "$TMPDIR/last-run-edl.log" 2>/dev/null || true
    fi
    rm -rf "$RUN"
}
trap cleanup EXIT

log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
die() { printf '[%s] STOP: %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; exit 1; }
kv() { sed -n "s/^$2=//p" "$1" | head -1; }
human() { numfmt --to=iec-i --suffix=B --format='%.1f' "$1"; }
secs() { echo "$2 - $1" | bc | sed 's/^\./0./'; }

set_unit_dir() { # move the run's logs into the unit's folder; log there from now on
    UD=$1
    mkdir -p "$UD"
    cat "$LOG" >> "$UD/install-$TS.log" 2>/dev/null || true
    cat "$EDL_LOG" >> "$UD/edl-$TS.log" 2>/dev/null || true
    LOG=$UD/install-$TS.log
    EDL_LOG=$UD/edl-$TS.log
}

# ------------------------------------------------------------------ edl

read -r -a EDL_CMD <<< "${TSV_EDL:-$ROOT/tools/edl/.venv/bin/python $ROOT/tools/edl/edl.py}"
EDL_EXTRA=()
[ -n "$LOADER" ] && EDL_EXTRA=("--loader=$LOADER")
N_EDL=0; LAST_SECS=0; LAST_RATE=""
edl() {
    local t0 t1 rc out=$RUN/edl.out
    t0=$(date +%s.%N)
    set +e
    "${EDL_CMD[@]}" "$@" "${EDL_EXTRA[@]}" > "$out" 2>&1
    rc=$?
    set -e
    t1=$(date +%s.%N)
    N_EDL=$((N_EDL + 1))
    LAST_SECS=$(secs "$t0" "$t1")
    LAST_RATE=$(sed -e 's/\x1b\[[0-9;]*m//g' "$out" | tr '\r' '\n' | grep -o -E '[0-9.]+ ?[KMG]B/s' | tail -1 || true)
    {
        echo "### edl $* -> rc $rc, $LAST_SECS s ${LAST_RATE:+(edl reports $LAST_RATE)}"
        sed -e 's/\x1b\[[0-9;]*m//g' "$out" | tr '\r' '\n' | grep -v -E '^\s*$|Progress:'
    } >> "$EDL_LOG"
    return $rc
}

# ------------------------------------------------------------------ reads and writes
# MODE=plan only prints (the plan and --dry-run); MODE=exec runs.
MODE=exec
PLAN_N=0; PLAN_R=0; PLAN_W=0
op_line() { # kind start count label
    printf '  %-7s LBA %9d +%9d sectors  %10s  %s\n' "$1" "$2" "$3" "$(human $(($3 * 512)))" "$4" | tee -a "$LOG"
}

read_sectors() { # start count file label
    if [ "$MODE" = plan ]; then
        op_line READ "$1" "$2" "$4"; PLAN_N=$((PLAN_N + 1)); PLAN_R=$((PLAN_R + $2 * 512)); return 0
    fi
    op_line READ "$1" "$2" "$4"
    edl rs "$1" "$2" "$3" || die "edl rs $1 $2 failed (see $EDL_LOG)"
    [ "$(stat -c%s "$3")" = $(($2 * 512)) ] || die "edl rs $1 $2: short read"
    log "          read in $LAST_SECS s${LAST_RATE:+, edl reports $LAST_RATE}"
}

check_window() { # start count : refuse anything outside what the install may write
    local s=$1 n=$2
    [ "$s" = 0 ] && [ "$n" = 34 ] && return 0
    [ "$s" = $((TOTAL - 33)) ] && [ "$n" = 33 ] && return 0
    [ "$s" -ge "$BOOT_S" ] && [ $((s + n)) -le $((BOOT_S + BOOT_N)) ] && return 0
    [ "$s" -ge "$SYSTEM_START" ] && [ $((s + n)) -le $((TOTAL - 33)) ] && return 0
    die "refusing to write LBA $s +$n: outside GPT, boot and $SYSTEM_START..$((TOTAL - 34))"
}

write_sectors() { # file start label [count-for-plan]   (file is a whole number of sectors)
    local f=$1 s=$2 label=$3 n
    if [ "$MODE" = plan ]; then
        n=${4:-$(($(stat -c%s "$f") / 512))}
        check_window "$s" "$n"
        op_line WRITE "$s" "$n" "$label"
        op_line READ "$s" "$n" "$label: read back and compare"
        PLAN_N=$((PLAN_N + 2)); PLAN_W=$((PLAN_W + n * 512)); PLAN_R=$((PLAN_R + n * 512))
        return 0
    fi
    [ $(($(stat -c%s "$f") % 512)) = 0 ] || die "$f is not a whole number of sectors"
    n=$(($(stat -c%s "$f") / 512))
    check_window "$s" "$n"
    local sha; sha=$(sha256sum "$f" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$s" "$n" "$sha" "$label" >> "$UD/writes.tsv"
    op_line WRITE "$s" "$n" "$label"
    edl ws "$s" "$f" || die "edl ws $s failed: $label (re-run to resume; see $EDL_LOG)"
    log "          written in $LAST_SECS s${LAST_RATE:+, edl reports $LAST_RATE}"
    read_sectors "$s" "$n" "$RUN/readback.img" "$label: read back"
    cmp -s "$f" "$RUN/readback.img" || die "$label: read back differs from what was written"
    rm -f "$RUN/readback.img"
    log "          $label: read back identical (sha256 ${sha:0:16}...)"
}

same_on_disk() { # file start label : 0 if the disk already holds exactly this file
    local n=$(($(stat -c%s "$1") / 512))
    read_sectors "$2" "$n" "$RUN/ondisk.img" "$3: already there?"
    if cmp -s "$1" "$RUN/ondisk.img"; then rm -f "$RUN/ondisk.img"; return 0; fi
    rm -f "$RUN/ondisk.img"; return 1
}

# ------------------------------------------------------------------ tables

declare -A NSTART NSIZE OSTART OSIZE
load_table() { # gpt-primary-file  -> NSTART/NSIZE (planned) or OSTART/OSIZE (current)
    local which=$2 num name start size rest
    while IFS=$'\t' read -r num name start size rest; do
        if [ "$which" = new ]; then NSTART[$name]=$start; NSIZE[$name]=$size
        else OSTART[$name]=$start; OSIZE[$name]=$size; fi
    done < <($TSV table "$1")
}

build_layout() { # stock-primary stock-backup outdir : this unit's stage-B GPT, as stage-B built it
    local p=$1 b=$2 d=$3 src=$RUN/layout-src.img new=$RUN/layout-new.img
    mkdir -p "$d"
    truncate -s $((TOTAL * 512)) "$src" "$new"
    dd if="$p" of="$src" conv=notrunc status=none
    dd if="$b" of="$src" bs=512 seek=$((TOTAL - 33)) conv=notrunc status=none
    sfdisk -d "$src" > "$d/stock.sfdisk" 2>/dev/null || die "sfdisk cannot read this unit's stock GPT"
    python3 -I "$SB/make-layout.py" "$d/stock.sfdisk" > "$d/layout.sfdisk" || die "make-layout.py failed"
    sfdisk -q --no-reread --no-tell-kernel "$new" < "$d/layout.sfdisk" 2>&1 | tee -a "$LOG"
    sfdisk --verify "$new" > /dev/null || die "sfdisk --verify on the new layout"
    python3 -I "$SB/make-gpt-blobs.py" --selftest "$p" "$b" | tee -a "$LOG"
    python3 -I "$SB/make-gpt-blobs.py" --pmbr "$p" "$new" "$d" > /dev/null
    rm -f "$src" "$new"
    $TSV classify "$d/primary.bin" "$d/backup.bin" "$TOTAL" > "$d/classify.txt"
    [ "$(kv "$d/classify.txt" state)" = stageb ] || die "generated table does not classify as stage-B"
    $TSV uuids-kept "$p" "$d/primary.bin" | tee -a "$LOG"
    (cd "$d" && sha256sum primary.bin backup.bin layout.sfdisk > SHA256SUMS)
    log "new GPT for this unit: $d/primary.bin (LBA 0, 34 sectors), backup.bin (LBA $((TOTAL - 33)), 33 sectors)"
}

# ------------------------------------------------------------------ preflight

check_tools() {
    local t
    for t in python3 sfdisk zstd sha256sum cmp dd truncate numfmt bc; do
        command -v "$t" > /dev/null || die "missing tool: $t"
    done
    if [ -z "${TSV_EDL:-}" ]; then
        [ -x "$ROOT/tools/edl/.venv/bin/python" ] || die "tools/edl is not set up (FLASHING.md)"
    fi
    if [ "${TSV_SKIP_USB_CHECK:-0}" != 1 ]; then
        command -v lsusb > /dev/null || die "missing tool: lsusb"
        lsusb | grep -q '05c6:9008' || die "no Qualcomm EDL device (05c6:9008) on USB; enter EDL first (FLASHING.md step 1)"
        log "USB: $(lsusb | grep '05c6:9008' | sed 's/^Bus [0-9]* Device [0-9]*: //')"
    fi
}

check_payload() {
    [ -f "$IMG" ] && [ -f "$IMG.sha256" ] || die "image or its .sha256 missing: $IMG"
    [ -f "$LK2ND" ] && [ -f "$LK2ND.sha256" ] || die "lk2nd or its .sha256 missing: $LK2ND"
    log "checking image and lk2nd checksums"
    (cd "$(dirname "$IMG")" && sha256sum --quiet -c "$(basename "$IMG").sha256") || die "image checksum"
    (cd "$(dirname "$LK2ND")" && sha256sum --quiet -c "$(basename "$LK2ND").sha256") || die "lk2nd checksum"
    IMG_SHA=$(cut -d' ' -f1 "$IMG.sha256")
    LK_SHA=$(cut -d' ' -f1 "$LK2ND.sha256")
    $TSV check-lk2nd "$LK2ND" 33554432 | tee -a "$LOG"
    $TSV check-image "$IMG" 99999999 > "$RUN/image.txt"
    IMG_SECTORS=$(kv "$RUN/image.txt" sectors); P2_START=$(kv "$RUN/image.txt" p2_start)
    log "image: $(basename "$IMG"), $IMG_SECTORS sectors ($(human $((IMG_SECTORS * 512)))), sha256 ${IMG_SHA:0:16}..., root at MBR sector $P2_START"
    log "lk2nd: $(basename "$LK2ND"), sha256 ${LK_SHA:0:16}..."
}

identify() {
    log "edl printgpt (identifies the chip, loads the programmer, lists the table)"
    if ! edl printgpt; then log "edl printgpt returned an error (a damaged primary table does this); continuing with raw reads"; fi
    cp "$RUN/edl.out" "$RUN/printgpt.log"
    $TSV parse-edl "$RUN/printgpt.log" > "$RUN/identity.txt"
    local hwid pk mode emmc sess=$UNITS/.edl-session
    hwid=$(kv "$RUN/identity.txt" hwid); pk=$(kv "$RUN/identity.txt" pk_hash)
    mode=$(kv "$RUN/identity.txt" mode); emmc=$(kv "$RUN/identity.txt" emmc_serial)
    TOTAL=$(kv "$RUN/identity.txt" total_blocks)
    [ -n "$emmc" ] && [ -n "$TOTAL" ] || die "edl did not report the storage (no firehose connection?)"
    [ "$(kv "$RUN/identity.txt" block_size)" = 512 ] || die "sector size is not 512"
    if [ -n "$hwid" ]; then
        [ "$hwid" = "$HWID_OK" ] || die "HWID $hwid is not a CD-18781Y ($HWID_OK)"
        [ "$pk" = "$PK_OK" ] || die "PK hash ${pk:0:18}... is not Lenovo's CD-18781Y hash"
        printf 'emmc_serial=%s\nhwid=%s\npk_hash=%s\nwhen=%s\n' "$emmc" "$hwid" "$pk" "$(date -Is)" > "$sess"
        log "identity: HWID $hwid, PK hash ${pk:0:18}... (match CD-18781Y), loader $(kv "$RUN/identity.txt" loader)"
    elif [ "$mode" = firehose ] && [ -f "$sess" ] && [ "$(kv "$sess" emmc_serial)" = "$emmc" ] \
        && [ "$(kv "$sess" hwid)" = "$HWID_OK" ] && [ "$(kv "$sess" pk_hash)" = "$PK_OK" ]; then
        log "identity: programmer already running; HWID and PK hash checked earlier in this EDL session ($(kv "$sess" when))"
    else
        die "no HWID/PK hash from Sahara and no earlier check in this session: unplug, re-enter EDL, run again"
    fi
    HWID=$HWID_OK; EMMC_SERIAL=$emmc
    EMMC_NAME=$(kv "$RUN/identity.txt" prod_name)
    log "storage: eMMC $EMMC_NAME, $TOTAL sectors of 512 bytes ($(human $((TOTAL * 512))))"

    read_sectors 0 34 "$RUN/disk-primary.bin" "GPT primary copy"
    read_sectors $((TOTAL - 33)) 33 "$RUN/disk-backup.bin" "GPT backup copy"
    read_sectors "$DEVINFO_LBA" 1 "$RUN/devinfo0.bin" "devinfo, first sector (serial number)"
    SERIAL=$($TSV devinfo-serial "$RUN/devinfo0.bin") || die "cannot read the serial number from devinfo"
    rm -f "$RUN/devinfo0.bin"
    $TSV classify "$RUN/disk-primary.bin" "$RUN/disk-backup.bin" "$TOTAL" > "$RUN/classify.txt"
    STATE=$(kv "$RUN/classify.txt" state)
    log "unit $SERIAL: partition table '$STATE' (primary $(kv "$RUN/classify.txt" primary)$(w=$(kv "$RUN/classify.txt" primary_why); [ -n "$w" ] && echo ": $w"), backup $(kv "$RUN/classify.txt" backup)$(w=$(kv "$RUN/classify.txt" backup_why); [ -n "$w" ] && echo ": $w"))"
}

explains() { # unit-dir : every readable copy on disk is the saved or the planned copy
    local d=$1 pk bk
    pk=$(kv "$RUN/classify.txt" primary); bk=$(kv "$RUN/classify.txt" backup)
    [ "$pk" = invalid ] && [ "$bk" = invalid ] && return 1
    if [ "$pk" != invalid ]; then
        cmp -s "$RUN/disk-primary.bin" "$d/gpt/primary.bin" || cmp -s "$RUN/disk-primary.bin" "$d/gpt-new/primary.bin" || return 1
    fi
    if [ "$bk" != invalid ]; then
        cmp -s "$RUN/disk-backup.bin" "$d/gpt/backup.bin" || cmp -s "$RUN/disk-backup.bin" "$d/gpt-new/backup.bin" || return 1
    fi
}

find_unit_dir() { # an unfinished run (backup taken, something written) that explains the disk
    local d
    for d in $(ls -1d "$UNITS/$SERIAL"-* 2> /dev/null | sort -r); do
        [ -e "$d/backup.ok" ] && [ ! -e "$d/install.done" ] && [ -s "$d/writes.tsv" ] || continue
        explains "$d" && { echo "$d"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------------ steps

step_backup() {
    if [ "$RESUME" = 1 ]; then
        if [ "$MODE" = plan ]; then
            echo "  backup: reuse $UD (taken $(kv "$UD/unit.env" DATE)); decompress and check it" | tee -a "$LOG"
            return 0
        fi
        log "backup: reusing $UD; reading it back from the laptop"
        $TSV verify-backup "$UD" | tee -a "$LOG"
        return 0
    fi
    local skip=userdata start count
    [ "$NO_SYS_BACKUP" = 1 ] && skip=userdata,system
    [ "$MODE" = plan ] && echo "  backup of every partition except $skip, then GPT copies; compressed, SHA256SUMS, read back from the laptop:" | tee -a "$LOG"
    while IFS=$'\t' read -r start count; do
        read_sectors "$start" "$count" "$RUN/region.img" "backup region"
        if [ "$MODE" = exec ]; then
            log "          slicing into partitions, compressing"
            $TSV slice "$RUN/disk-primary.bin" "$RUN/region.img" "$start" "$UD" "$skip" | tee -a "$LOG"
            rm -f "$RUN/region.img"
        fi
    done < <($TSV backup-plan "$RUN/disk-primary.bin" "$skip")
    [ "$MODE" = plan ] && return 0
    mkdir -p "$UD/gpt"
    cp "$RUN/disk-primary.bin" "$UD/gpt/primary.bin"
    cp "$RUN/disk-backup.bin" "$UD/gpt/backup.bin"
    (cd "$UD" && sha256sum gpt/primary.bin gpt/backup.bin >> SHA256SUMS)
    cp "$RUN/printgpt.log" "$UD/printgpt.log"; cp "$RUN/classify.txt" "$UD/classify.txt"
    log "backup: verifying by reading every file back from the laptop"
    $TSV verify-backup "$UD" | tee -a "$LOG"
    {
        echo "SERIAL=$SERIAL"; echo "HWID=$HWID"; echo "EMMC_SERIAL=$EMMC_SERIAL"; echo "EMMC_NAME=$EMMC_NAME"
        echo "TOTAL=$TOTAL"; echo "ORIGIN=$STATE"; echo "DATE=$(date -Is)"
        echo "SYSTEM_BACKED_UP=$([ "$NO_SYS_BACKUP" = 1 ] && echo no || echo yes)"
    } > "$UD/unit.env"
    touch "$UD/backup.ok"
    log "backup: complete, $(du -sh --apparent-size "$UD" | cut -f1) in $UD"
}

step_tail() {
    [ "$ORIGIN" = stock ] || return 0
    local ts=${NSTART[persist]} te=$((NSTART[msadp] + NSIZE[msadp])) n off
    [ "$MODE" = plan ] && echo "  tail: persist syscfg mcfg apdp msadp, from this unit's backup, to their stage-B places (one write):" | tee -a "$LOG"
    if [ "$MODE" = plan ]; then
        read_sectors "$ts" $((te - ts)) - "tail: already there?"
        write_sectors - "$ts" "tail partitions" $((te - ts))
        return 0
    fi
    truncate -s $(((te - ts) * 512)) "$RUN/tail.img"
    for n in $TAIL; do
        zstd -dc -q "$UD/partitions/$n.img.zst" > "$RUN/$n.img"
        [ "$(sha256sum < "$RUN/$n.img" | cut -d' ' -f1)" = "$(awk -v f="partitions/$n.img" '$2 == f { print $1 }' "$UD/SHA256SUMS")" ] \
            || die "$n: backup image does not match SHA256SUMS"
        [ "$(($(stat -c%s "$RUN/$n.img") / 512))" = "${NSIZE[$n]}" ] || die "$n: size differs from the new table"
        if [ "$BACKUP_FRESH" = 0 ] && [ "$STATE" = stock ]; then
            # resumed with an older backup: the unit's own partition must still be what was backed up
            read_sectors "${OSTART[$n]}" "${OSIZE[$n]}" "$RUN/src.img" "$n at its stock place (unchanged since the backup?)"
            cmp -s "$RUN/$n.img" "$RUN/src.img" || die "$n changed since the backup; run again with --fresh-backup"
            rm -f "$RUN/src.img"
        fi
        off=$((NSTART[$n] - ts))
        dd if="$RUN/$n.img" of="$RUN/tail.img" bs=512 seek=$off conv=notrunc status=none
        rm -f "$RUN/$n.img"
    done
    if same_on_disk "$RUN/tail.img" "$ts" "tail"; then
        log "tail: already at the new places (earlier run)"
    else
        write_sectors "$RUN/tail.img" "$ts" "tail partitions"
    fi
    rm -f "$RUN/tail.img"
    echo "tail $ts $te" >> "$UD/progress"
}

step_gpt() {
    if [ "$MODE" = plan ]; then
        if cmp -s "$RUN/disk-backup.bin" "$NEW_B" && cmp -s "$RUN/disk-primary.bin" "$NEW_P"; then
            echo "  GPT: already the stage-B table, nothing to write" | tee -a "$LOG"; return 0
        fi
        echo "  GPT: backup copy first, then the primary:" | tee -a "$LOG"
        cmp -s "$RUN/disk-backup.bin" "$NEW_B" || write_sectors "$NEW_B" $((TOTAL - 33)) "GPT backup copy (stage-B)"
        cmp -s "$RUN/disk-primary.bin" "$NEW_P" || write_sectors "$NEW_P" 0 "GPT primary copy (stage-B)"
        return 0
    fi
    if cmp -s "$RUN/disk-backup.bin" "$NEW_B"; then log "GPT backup copy: already stage-B"
    else write_sectors "$NEW_B" $((TOTAL - 33)) "GPT backup copy (stage-B)"; fi
    if cmp -s "$RUN/disk-primary.bin" "$NEW_P"; then log "GPT primary copy: already stage-B"
    else write_sectors "$NEW_P" 0 "GPT primary copy (stage-B)"; fi
    read_sectors 0 34 "$RUN/disk-primary.bin" "GPT primary copy (final check)"
    read_sectors $((TOTAL - 33)) 33 "$RUN/disk-backup.bin" "GPT backup copy (final check)"
    cmp -s "$RUN/disk-primary.bin" "$NEW_P" && cmp -s "$RUN/disk-backup.bin" "$NEW_B" || die "GPT on disk is not the new table"
    [ "$($TSV classify "$RUN/disk-primary.bin" "$RUN/disk-backup.bin" "$TOTAL" | kv /dev/stdin state)" = stageb ] || die "GPT does not classify as stage-B"
    log "GPT: stage-B, both copies byte-identical to this unit's new table"
    echo "gpt stageb" >> "$UD/progress"
}

step_system() {
    local s=${NSTART[system]}
    [ "$IMG_SECTORS" -le "${NSIZE[system]}" ] || die "image ($IMG_SECTORS sectors) does not fit system (${NSIZE[system]})"
    if [ "$MODE" = exec ] && grep -qx "system $IMG_SHA $s" "$UD/progress" 2> /dev/null; then
        log "system: this image was written and verified by an earlier run"; return 0
    fi
    [ "$MODE" = plan ] && echo "  system: the Straylight image into p24 'system':" | tee -a "$LOG"
    write_sectors "$IMG" "$s" "system image"
    [ "$MODE" = exec ] && echo "system $IMG_SHA $s" >> "$UD/progress"
    return 0
}

step_boot() {
    local s=${NSTART[boot]}
    [ "$MODE" = plan ] && echo "  boot: lk2nd into p21 'boot' (last, the switch from the old system to Straylight):" | tee -a "$LOG"
    if [ "$MODE" = plan ]; then
        local n=$((($(stat -c%s "$LK2ND") + 511) / 512))
        read_sectors "$s" "$n" - "boot: already lk2nd?"
        write_sectors - "$s" "lk2nd" "$n"
        return 0
    fi
    cp "$LK2ND" "$RUN/lk2nd.img"
    truncate -s $((($(stat -c%s "$LK2ND") + 511) / 512 * 512)) "$RUN/lk2nd.img"
    [ "$(stat -c%s "$RUN/lk2nd.img")" -le $((NSIZE[boot] * 512)) ] || die "lk2nd does not fit boot"
    if same_on_disk "$RUN/lk2nd.img" "$s" "boot"; then log "boot: already this lk2nd"
    else write_sectors "$RUN/lk2nd.img" "$s" "lk2nd"; fi
    echo "boot $LK_SHA $s" >> "$UD/progress"
}

step_reset() {
    if [ "$MODE" = plan ]; then echo "  RESET   edl reset --resetmode=reset" | tee -a "$LOG"; PLAN_N=$((PLAN_N + 1)); return 0; fi
    log "reset: edl reset --resetmode=reset"
    edl reset --resetmode=reset || die "edl reset failed (the install itself is complete; power-cycle the unit)"
    echo "reset" >> "$UD/progress"
    touch "$UD/install.done"
    log "install complete; the unit is rebooting"
}

# ------------------------------------------------------------------ first boot

boot_report_script() {
    cat << 'EOF'
echo p24=$(cat /sys/class/block/mmcblk0p24/size)
echo nparts=$(ls -d /sys/class/block/mmcblk0p* | wc -l)
src=$(findmnt -no SOURCE /); echo rootdev=$src; echo rootsz=$(blockdev --getsz $src)
echo growroot=$(test -e /var/lib/tsv/growroot.done && echo done || echo pending)
echo state=$(systemctl is-system-running)
for u in UNITS; do echo "unit:$u=$(systemctl is-active $u)"; done
echo failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')
for n in persist syscfg mcfg apdp msadp; do echo "sha:$n=$(sha256sum /dev/disk/by-partlabel/$n | cut -d' ' -f1)"; done
echo df=$(df -h --output=size,avail / | tail -1)
EOF
}

check_boot() { # unit-dir
    local d=$1 adb=${TSV_ADB:-adb} ser="" t0 rep=$RUN/boot.txt
    load_table "$d/gpt-new/primary.bin" new
    [ -n "${P2_START:-}" ] || { $TSV check-image "$IMG" 99999999 > "$RUN/image.txt"; P2_START=$(kv "$RUN/image.txt" p2_start); }
    log "first boot: waiting for adb (model ThinkSmart_View), up to 240 s"
    t0=$(date +%s)
    until ser=$($adb devices -l 2> /dev/null | awk '/model:ThinkSmart_View/ { print $1; exit }') && [ -n "$ser" ]; do
        [ $(($(date +%s) - t0)) -lt 240 ] || { log "first boot: no adb after 240 s. Stop; do not retry (FLASHING.md, 'If it does not boot')"; return 1; }
        sleep 3
    done
    log "first boot: adb $ser after $(($(date +%s) - t0)) s"
    local script; script=$(boot_report_script | sed "s/UNITS/$SERVICES/")
    while :; do
        $adb -s "$ser" shell "$script" > "$rep" 2> /dev/null || true
        case "$(kv "$rep" state)" in starting|initializing|"") ;; *) [ "$(kv "$rep" growroot)" = done ] && break ;; esac
        [ $(($(date +%s) - t0)) -lt 420 ] || { log "first boot: system not settled after 420 s"; break; }
        sleep 5
    done
    local ok=1 want_root=$((NSIZE[system] - P2_START)) n u h
    chk() { if [ "$2" = "$3" ]; then log "  OK    $1: $2"; else log "  FAIL  $1: $2 (expected $3)"; ok=0; fi; }
    chk "p24 'system' sectors (kernel view)" "$(kv "$rep" p24)" "${NSIZE[system]}"
    chk "partitions the kernel sees" "$(kv "$rep" nparts)" 29
    chk "root grown ($(kv "$rep" rootdev), sectors)" "$(kv "$rep" rootsz)" "$want_root"
    chk "tsv-growroot" "$(kv "$rep" growroot)" done
    chk "system state" "$(kv "$rep" state)" running
    for u in $SERVICES; do chk "service $u" "$(kv "$rep" "unit:$u")" active; done
    for n in $TAIL; do
        h=$(awk -v f="partitions/$n.img" '$2 == f { print $1 }' "$d/SHA256SUMS")
        chk "$n by label, sha256" "$(kv "$rep" "sha:$n" | cut -c1-16)" "${h:0:16}"
    done
    [ -n "$(kv "$rep" failed | tr -d ' ')" ] && log "  failed units: $(kv "$rep" failed)"
    log "  root: $(kv "$rep" df) (size, free)"
    [ "$ok" = 1 ] && log "first boot: all checks passed" || log "first boot: some checks failed (see above)"
    cp "$rep" "$d/firstboot-$TS.txt"
    [ "$ok" = 1 ]
}

# ------------------------------------------------------------------ plan and confirm

print_estimate() {
    local s; s=$(echo "$PLAN_N * $EDL_CALL_S + ($PLAN_R + $PLAN_W) / ($EDL_MBPS * 1000000)" | bc)
    printf '  %d edl calls, %s read, %s written: about %d min %02d s over EDL (at %d MB/s and %d s per call)\n' \
        "$PLAN_N" "$(human $PLAN_R)" "$(human $PLAN_W)" $((s / 60)) $((s % 60)) "$EDL_MBPS" "$EDL_CALL_S" | tee -a "$LOG"
}

confirm() {
    [ "$DRY" = 1 ] && { log "dry run: nothing written, nothing backed up"; exit 0; }
    printf '\nType the serial number of this unit (%s) to start: ' "$SERIAL"
    local ans
    read -r ans || die "no confirmation; nothing written"
    echo
    [ "$ans" = "$SERIAL" ] || die "confirmation does not match; nothing written"
    log "confirmed by serial number"
}

# ------------------------------------------------------------------ install

install_main() {
    check_tools
    check_payload
    identify
    RESUME=0; BACKUP_FRESH=1; ORIGIN=$STATE
    local found=""
    case "$STATE" in
        stock|stageb)
            if [ "$FRESH" = 0 ] && found=$(find_unit_dir); then RESUME=1; fi ;;
        half)
            found=$(find_unit_dir) || die "the table is half written and no unfinished run in $UNITS explains it; use --restore <dir>"
            RESUME=1 ;;
        *) die "partition table is neither stock nor stage-B; nothing written (details: $(kv "$RUN/classify.txt" primary_why) / $(kv "$RUN/classify.txt" backup_why))" ;;
    esac
    if [ "$RESUME" = 1 ]; then
        BACKUP_FRESH=0
        ORIGIN=$(kv "$found/unit.env" ORIGIN)
        [ "$(kv "$found/unit.env" SERIAL)" = "$SERIAL" ] && [ "$(kv "$found/unit.env" TOTAL)" = "$TOTAL" ] || die "$found is not this unit"
        set_unit_dir "$found"
        log "resuming the unfinished run in $UD (started from a '$ORIGIN' table; $(wc -l < "$UD/writes.tsv") writes logged)"
        (cd "$UD/gpt-new" && sha256sum --quiet -c SHA256SUMS) || die "$UD/gpt-new: checksum mismatch"
        PLAN_DIR=$UD/gpt-new
    else
        PLAN_DIR=$RUN/plan/gpt-new
        if [ "$STATE" = stock ]; then
            log "building this unit's stage-B table from its own stock table (make-layout.py, make-gpt-blobs.py)"
            build_layout "$RUN/disk-primary.bin" "$RUN/disk-backup.bin" "$PLAN_DIR"
        else
            mkdir -p "$PLAN_DIR"
            cp "$RUN/disk-primary.bin" "$PLAN_DIR/primary.bin"; cp "$RUN/disk-backup.bin" "$PLAN_DIR/backup.bin"
            (cd "$PLAN_DIR" && sha256sum primary.bin backup.bin > SHA256SUMS)
            log "already stage-B: the table stays as it is"
        fi
    fi
    NEW_P=$PLAN_DIR/primary.bin; NEW_B=$PLAN_DIR/backup.bin
    load_table "$NEW_P" new
    if [ "$(kv "$RUN/classify.txt" primary)" = stock ]; then load_table "$RUN/disk-primary.bin" old; fi
    BOOT_S=${NSTART[boot]}; BOOT_N=${NSIZE[boot]}
    local newud=$UNITS/$SERIAL-$(date +%Y%m%d) i=2
    if [ "$RESUME" = 0 ]; then while [ -e "$newud" ]; do newud=$UNITS/$SERIAL-$(date +%Y%m%d)-$i; i=$((i + 1)); done; fi

    {
        echo
        echo "PLAN for $SERIAL (eMMC $EMMC_NAME, $TOTAL sectors): table '$STATE'$([ "$RESUME" = 1 ] && echo ", resuming $UD")"
        echo "  backup folder: ${UD:-$newud}"
        echo "  image: $IMG"
        echo "  lk2nd: $LK2ND"
        echo "  system p24: LBA ${NSTART[system]} +${NSIZE[system]}; boot p21: LBA $BOOT_S +$BOOT_N"
    } | tee -a "$LOG"
    MODE=plan
    [ "$RESUME" = 1 ] || UD=$RUN/plan
    step_backup; step_tail; step_gpt; step_system; step_boot; step_reset
    print_estimate
    [ "$NO_WAIT" = 1 ] || echo "  then: wait for adb and check the first boot (root grown, services up)" | tee -a "$LOG"
    [ "$RESUME" = 1 ] || UD=""
    confirm

    MODE=exec
    if [ "$RESUME" = 0 ]; then
        set_unit_dir "$newud"
        mkdir -p "$UD/gpt-new"
        cp "$PLAN_DIR"/* "$UD/gpt-new/"
        PLAN_DIR=$UD/gpt-new; NEW_P=$PLAN_DIR/primary.bin; NEW_B=$PLAN_DIR/backup.bin
        log "unit folder: $UD"
    fi
    local t0; t0=$(date +%s)
    step_backup; step_tail; step_gpt; step_system; step_boot; step_reset
    log "EDL part done in $(($(date +%s) - t0)) s, $N_EDL edl calls"
    [ "$NO_WAIT" = 1 ] && { log "not waiting for the first boot (--no-wait); check later with --check-boot $UD"; return 0; }
    check_boot "$UD" || exit 1
}

# ------------------------------------------------------------------ restore

restore_main() {
    local d; d=$(cd "$RESTORE" && pwd) || die "no such folder: $RESTORE"
    [ -e "$d/backup.ok" ] || die "$d has no complete backup"
    check_tools
    identify
    [ "$(kv "$d/unit.env" SERIAL)" = "$SERIAL" ] || die "this unit is $SERIAL; $d is $(kv "$d/unit.env" SERIAL)"
    [ "$(kv "$d/unit.env" TOTAL)" = "$TOTAL" ] || die "disk size differs from the backup"
    set_unit_dir "$d"
    log "restore: checking the backup by reading it back from the laptop"
    $TSV verify-backup "$d" | tee -a "$LOG"
    load_table "$d/gpt/primary.bin" new
    BOOT_S=${NSTART[boot]}; BOOT_N=${NSIZE[boot]}
    [ "$(kv "$d/unit.env" SYSTEM_BACKED_UP)" = yes ] || log "note: 'system' was not backed up; it is not restored"
    $TSV restore-plan "$d" "$SYSTEM_START" > "$RUN/restore.tsv"
    local kind start count rel sha label pass
    for pass in plan exec; do
        MODE=$pass
        if [ "$pass" = plan ]; then
            echo; echo "RESTORE PLAN for $SERIAL from $d (table now '$STATE'; back to '$(kv "$d/unit.env" ORIGIN)'):" | tee -a "$LOG"
            echo "  every backed-up partition and gap the install can touch (boot, and LBA $SYSTEM_START on), then both GPT copies" | tee -a "$LOG"
        fi
        while IFS=$'\t' read -r kind start count rel sha label; do
            if [ "$pass" = exec ] && grep -qx "restored $start $sha" "$d/restore.progress" 2> /dev/null; then
                log "$label: restored by an earlier run"; continue
            fi
            if [ "$pass" = plan ]; then write_sectors - "$start" "$label" "$count"; continue; fi
            case "$kind" in
                gap-zero) truncate -s 0 "$RUN/r.img"; truncate -s $((count * 512)) "$RUN/r.img" ;;
                *) zstd -dc -q "$d/$rel" > "$RUN/r.img" ;;
            esac
            [ "$(sha256sum < "$RUN/r.img" | cut -d' ' -f1)" = "$sha" ] || die "$label: backup data does not match its sha256"
            write_sectors "$RUN/r.img" "$start" "$label"
            rm -f "$RUN/r.img"
            echo "restored $start $sha" >> "$d/restore.progress"
        done < "$RUN/restore.tsv"
        if [ "$pass" = plan ] || ! { cmp -s "$RUN/disk-backup.bin" "$d/gpt/backup.bin" && cmp -s "$RUN/disk-primary.bin" "$d/gpt/primary.bin"; }; then
            write_sectors "$d/gpt/backup.bin" $((TOTAL - 33)) "GPT backup copy (as backed up)"
            write_sectors "$d/gpt/primary.bin" 0 "GPT primary copy (as backed up)"
        fi
        if [ "$pass" = plan ]; then
            [ "$RESET_AFTER" = 1 ] && echo "  RESET   edl reset --resetmode=reset" | tee -a "$LOG"
            print_estimate; confirm
        fi
    done
    read_sectors 0 34 "$RUN/disk-primary.bin" "GPT primary copy (final check)"
    read_sectors $((TOTAL - 33)) 33 "$RUN/disk-backup.bin" "GPT backup copy (final check)"
    cmp -s "$RUN/disk-primary.bin" "$d/gpt/primary.bin" && cmp -s "$RUN/disk-backup.bin" "$d/gpt/backup.bin" \
        || die "GPT on disk differs from the backup"
    log "restore: GPT byte-identical to the backup ($($TSV classify "$RUN/disk-primary.bin" "$RUN/disk-backup.bin" "$TOTAL" | kv /dev/stdin state)); every restored range read back identical"
    echo "restore done $(date -Is)" >> "$d/restore.progress"
    if [ "$RESET_AFTER" = 1 ]; then edl reset --resetmode=reset || die "edl reset failed"; log "reset"; fi
}

if [ -n "$CHECK_ONLY" ]; then
    UD=$(cd "$CHECK_ONLY" && pwd); set_unit_dir "$UD"; check_boot "$UD"
elif [ -n "$RESTORE" ]; then
    restore_main
else
    install_main
fi
