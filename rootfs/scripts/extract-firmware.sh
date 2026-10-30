#!/usr/bin/env bash
# Extract the firmware mainline 7.3 needs from this device's own partition
# backups (read only) into a staging tree laid out as /lib/firmware.
#
#   extract-firmware.sh BACKUP_PARTITIONS_DIR WORK_DIR OUT_FW_DIR MANIFEST_TSV
#
# Nothing is mounted. modem.img (FAT16) is read with fatextract.py, vendor.img
# (ext4) with debugfs. Images are decompressed into WORK_DIR and their SHA-256
# checked against the on-device SHA256SUMS.device before use.
set -euo pipefail

BK=$1 WORK=$2 FW=$3 MANIFEST=$4
HERE=$(cd "$(dirname "$0")" && pwd)
FATX="python3 -I $HERE/fatextract.py"
FWPACK="python3 -I $HERE/ath10k-fwpack.py"

mkdir -p "$WORK"
for p in modem vendor; do
    if [[ ! -f $WORK/$p.img ]] || ! (cd "$WORK" && grep -E " $p\.img$" "$BK/SHA256SUMS.device" | sha256sum -c --quiet); then
        zstd -dqf "$BK/$p.img.zst" -o "$WORK/$p.img"
        (cd "$WORK" && grep -E " $p\.img$" "$BK/SHA256SUMS.device" | sha256sum -c --quiet)
    fi
done
echo "extract-firmware: modem.img and vendor.img match SHA256SUMS.device"

rm -rf "$FW"
mkdir -p "$FW"
DEV=qcom/msm8953/lenovo/cd-18781y
mkdir -p "$FW/$DEV" "$FW/qcom" "$FW/ath10k/QCA9379/hw1.0" "$FW/qca"
printf 'destination\tsource_partition\tsource_path\tsha256\tsize\n' > "$MANIFEST"

record() { # dest part srcpath
    local f=$FW/$1
    printf '/lib/firmware/%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" \
        "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")" >> "$MANIFEST"
}
from_modem() { # srcpath dest
    $FATX "$WORK/modem.img" get "$1" "$FW/$2"
    record "$2" modem "/firmware/$1"
}
from_vendor() { # srcpath dest
    debugfs -R "dump $1 $FW/$2" "$WORK/vendor.img" 2>/dev/null
    [[ -s $FW/$2 ]] || { echo "missing $1 in vendor.img" >&2; exit 1; }
    record "$2" vendor "/vendor$1"
}
link() { # linkname target (relative to /lib/firmware)
    ln -s "$2" "$FW/$1"
    printf '/lib/firmware/%s\t(symlink)\t-> %s\t-\t-\n' "$1" "$2" >> "$MANIFEST"
}

# ADSP: qcom,msm8953-adsp-pil -> msm8996_adsp_resource, firmware_name
# "adsp.mdt" (drivers/remoteproc/qcom_q6v5_pas.c). The 7.3 device DTS sets no
# firmware-name on &lpass, so the driver asks for /lib/firmware/adsp.mdt and the
# mdt loader asks for adsp.bNN next to it.
for f in $($FATX "$WORK/modem.img" ls image | awk '{print $3}' | grep -E '^image/adsp\.(mdt|b[0-9]+)$'); do
    b=${f#image/}
    from_modem "$f" "$DEV/$b"
    link "$b" "$DEV/$b"
done

# Venus: qcom,msm8953-venus -> msm8953_res.fwname "venus.mdt"
# (drivers/media/platform/qcom/venus/core.c). No firmware-name in the DTS.
for f in $($FATX "$WORK/modem.img" ls image | awk '{print $3}' | grep -E '^image/venus\.(mdt|b[0-9]+)$'); do
    b=${f#image/}
    from_modem "$f" "$DEV/$b"
    link "$b" "$DEV/$b"
done

# GPU zap shader: &gpu_zap_shader firmware-name =
# "qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt" (device DTS). Stock loads it
# from /vendor/firmware.
for b in a506_zap.mdt a506_zap.b00 a506_zap.b01 a506_zap.b02; do
    from_vendor "/firmware/$b" "$DEV/$b"
done

# GPU microcode: a5xx_catalog.c, a506 entry: a530_pm4.fw / a530_pfp.fw,
# requested as qcom/<name> first (adreno_gpu.c adreno_request_fw).
for b in a530_pm4.fw a530_pfp.fw; do
    from_vendor "/firmware/$b" "qcom/$b"
done

# Wi-Fi: QCA9379 hw1.0 SDIO, dir ath10k/QCA9379/hw1.0
# (drivers/net/wireless/ath/ath10k/hw.h), firmware-sdio-<api>.bin
# (core.c ath10k_core_get_fw_name), board.bin (API 1) or board-2.bin.
# Stock ships the raw image (athwlan.bin == qwlan30.bin), OTP (otp30.bin) and
# board data (bdwlan30.bin) in /firmware/image. ath10k needs API >= 2, so the
# raw image is wrapped in the ath10k-fwencoder container. Version string from
# /firmware/verinfo/ver_info.txt. WMI/HTT op versions "tlv" and the
# ignore-otp feature follow linux-firmware's QCA9377 firmware-sdio-5.bin;
# wowlan and mfp follow what the working 6.19 port reported.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
$FATX "$WORK/modem.img" get image/qwlan30.bin "$TMP/qwlan30.bin"
$FATX "$WORK/modem.img" get image/athwlan.bin "$TMP/athwlan.bin"
cmp -s "$TMP/qwlan30.bin" "$TMP/athwlan.bin" || { echo "qwlan30.bin != athwlan.bin" >&2; exit 1; }
$FATX "$WORK/modem.img" get image/otp30.bin "$TMP/otp30.bin"
$FATX "$WORK/modem.img" get verinfo/ver_info.txt "$TMP/ver_info.txt"
WLANVER=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["Image_Build_IDs"]["wlan"])' "$TMP/ver_info.txt")
[[ $WLANVER == WLAN.NPL.* ]] || { echo "unexpected wlan version $WLANVER" >&2; exit 1; }
# Fixed timestamp (metabuild time 2020-06-28 16:37:23 UTC) keeps the output reproducible.
$FWPACK pack --fw "$TMP/qwlan30.bin" --otp "$TMP/otp30.bin" --version "$WLANVER" \
    --timestamp 1593362243 --features wowlan,ignore-otp,mfp --wmi tlv --htt tlv \
    -o "$FW/ath10k/QCA9379/hw1.0/firmware-sdio-5.bin"
printf '/lib/firmware/%s\t%s\t%s\t%s\t%s\n' ath10k/QCA9379/hw1.0/firmware-sdio-5.bin modem \
    "/firmware/image/qwlan30.bin + otp30.bin (packed, $WLANVER)" \
    "$(sha256sum "$FW/ath10k/QCA9379/hw1.0/firmware-sdio-5.bin" | cut -d' ' -f1)" \
    "$(stat -c %s "$FW/ath10k/QCA9379/hw1.0/firmware-sdio-5.bin")" >> "$MANIFEST"
for f in qwlan30.bin otp30.bin; do
    printf '(input)\tmodem\t/firmware/image/%s\t%s\t%s\n' "$f" \
        "$(sha256sum "$TMP/$f" | cut -d' ' -f1)" "$(stat -c %s "$TMP/$f")" >> "$MANIFEST"
done
# Board data: sha256 65767cca... is the file Felix Kaechele used upstream
# (ath10k list, 2024-08, "board_file api 1 ... crc32 05c45515").
from_modem image/bdwlan30.bin ath10k/QCA9379/hw1.0/board.bin
want=65767cca6a1ff88a9899235acdeeed1e9447a2f16f41d38052202835d5bda7d4
[[ $(sha256sum "$FW/ath10k/QCA9379/hw1.0/board.bin" | cut -d' ' -f1) == "$want" ]] \
    || echo "WARNING: board.bin differs from the upstream-tested board file" >&2

# Bluetooth: compatible "qcom,qca6174-bt" -> QCA_ROME in hci_qca.c; btqca.c
# asks for qca/rampatch_%08x.bin and qca/nvm_%08x.bin by SoC version. For
# QCA9379-3 that is 00150100 (Felix Kaechele, "Bluetooth: hci_qca: add
# compatible for QCA9379", 2024-08). Stock names: btfwnpla.tlv / btnvnpla.bin.
from_modem image/btfwnpla.tlv qca/rampatch_00150100.bin
from_modem image/btnvnpla.bin qca/nvm_00150100.bin

find "$FW" -type f -exec chmod 0644 {} +
echo "extract-firmware: $(find "$FW" -type f | wc -l) files, $(du -sh "$FW" | cut -f1) -> $FW"
