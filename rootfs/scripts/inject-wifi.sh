#!/usr/bin/env bash
# Add a NetworkManager Wi-Fi profile (autoconnect, retry forever) to the root
# filesystem of a ThinkSmart system image, in place, without mounting.
#
#   inject-wifi.sh [--image IMG] --ssid SSID --psk PSK
#   inject-wifi.sh [--image IMG] --ssid SSID --psk -        # read PSK from stdin
#
# IMG defaults to rootfs/out/thinksmart-alarm-system.img. The PSK is written
# only into the image (file mode 0600, root:root); the temporary keyfile is
# created in a private 0700 directory and removed. Nothing is logged.
# Re-running with the same SSID replaces the profile.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$HERE/../out/thinksmart-alarm-system.img
SSID="" PSK="" HAVE_PSK=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --image) IMG=$2; shift 2 ;;
        --ssid) SSID=$2; shift 2 ;;
        --psk) PSK=$2; HAVE_PSK=1; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $SSID && -n $HAVE_PSK ]] || { echo "need --ssid and --psk" >&2; exit 2; }
if [[ $PSK == - ]]; then
    IFS= read -r PSK
fi
if (( ${#PSK} < 8 || ${#PSK} > 64 )); then
    echo "PSK must be 8..63 characters (or 64 hex digits)" >&2; exit 2
fi
case $SSID in *$'\n'*|*/*) echo "SSID must not contain newlines or '/'" >&2; exit 2 ;; esac
[[ -f $IMG ]] || { echo "no image at $IMG" >&2; exit 1; }

# Locate the root filesystem (label tsv-root) among the MBR partitions.
OFF=""
while read -r start; do
    o=$((start * 512))
    if debugfs -R stats "$IMG?offset=$o" 2>/dev/null | grep -q '^Filesystem volume name: *tsv-root$'; then
        OFF=$o
    fi
done < <(sfdisk -d "$IMG" | sed -n 's/.*start= *\([0-9]*\),.*/\1/p')
[[ -n $OFF ]] || { echo "tsv-root filesystem not found in $IMG" >&2; exit 1; }
FS="$IMG?offset=$OFF"

DIR=/etc/NetworkManager/system-connections
NAME=$SSID.nmconnection
debugfs -R "stat $DIR" "$FS" 2>/dev/null | grep -q 'Type: directory' ||
    { echo "$DIR missing in image" >&2; exit 1; }

umask 077
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
UUID=$(cat /proc/sys/kernel/random/uuid)
# keyfile values: escape backslashes and semicolons is not needed for ssid=
# in NM keyfile when written as a plain string; reject ';' to stay safe.
case $SSID$PSK in *';'*|*$'\\'*) echo "';' and '\\' are not supported by this script" >&2; exit 2 ;; esac
cat > "$TMPD/conn" <<EOF
[connection]
id=$SSID
uuid=$UUID
type=wifi
autoconnect=true
autoconnect-priority=10
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
PSK=""

{
    echo "rm $DIR/$NAME"
    echo "write $TMPD/conn $DIR/$NAME"
    echo "set_inode_field $DIR/$NAME uid 0"
    echo "set_inode_field $DIR/$NAME gid 0"
    echo "set_inode_field $DIR/$NAME mode 0100600"
} | debugfs -w -f - "$FS" >/dev/null 2>&1 || true

# Verify (without printing the secret).
st=$(debugfs -R "stat $DIR/$NAME" "$FS" 2>/dev/null)
grep -q 'Mode:  0600' <<<"$st" && grep -q 'User:     0   Group:     0' <<<"$st" ||
    { echo "inject failed:"; grep -E 'Mode|User' <<<"$st"; exit 1; }
size=$(debugfs -R "stat $DIR/$NAME" "$FS" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)
[[ $size == $(stat -c %s "$TMPD/conn") ]] || { echo "size mismatch" >&2; exit 1; }
e2fsck -fn "$FS" >/dev/null 2>&1 || { echo "e2fsck reports problems after inject" >&2; exit 1; }
echo "inject-wifi: added $DIR/$NAME (0600 root:root) to $(basename "$IMG")"
echo "inject-wifi: the image checksum in out/*.sha256 no longer matches; that is expected."
