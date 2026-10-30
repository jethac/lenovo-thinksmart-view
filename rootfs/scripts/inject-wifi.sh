#!/usr/bin/env bash
# Add a NetworkManager Wi-Fi profile (autoconnect, retry forever, the unit's
# own MAC) either to the root filesystem of a ThinkSmart system image, in place
# and without mounting, or to the running device over adb.
#
#   inject-wifi.sh [--image IMG] --ssid SSID --psk PSK
#   inject-wifi.sh [--image IMG] --ssid SSID --psk -        # read PSK from stdin
#   inject-wifi.sh --adb [--serial S] --ssid SSID --psk - < ~/.config/tsv/wifi.psk
#
# IMG defaults to rootfs/out/thinksmart-alarm-system.img. With --adb the
# profile is streamed over adb's stdin into the device's
# /etc/NetworkManager/system-connections (0600 root:root) and NetworkManager
# reloads it; the PSK is never on a command line, in a log, or in a file
# outside that directory. For images, the temporary keyfile is created in a
# private 0700 directory and removed. Re-running with the same SSID replaces
# the profile.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$HERE/../out/thinksmart-alarm-system.img
SSID="" PSK="" HAVE_PSK="" ADB="" SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
while [[ $# -gt 0 ]]; do
    case $1 in
        --image) IMG=$2; shift 2 ;;
        --adb) ADB=1; shift ;;
        --serial) SERIAL=$2; shift 2 ;;
        --ssid) SSID=$2; shift 2 ;;
        --psk) PSK=$2; HAVE_PSK=1; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $SSID && -n $HAVE_PSK ]] || { echo "need --ssid and --psk" >&2; exit 2; }
if [[ $PSK == - ]]; then
    IFS= read -r PSK || [[ -n $PSK ]]
fi
PSK=${PSK%$'\r'}
if (( ${#PSK} < 8 || ${#PSK} > 64 )); then
    echo "PSK must be 8..63 characters (or 64 hex digits)" >&2; exit 2
fi
case $SSID in *$'\n'*|*/*|*\"*|*\$*|*\`*) echo "SSID must not contain newlines, '/', '\"', '\$' or '\`'" >&2; exit 2 ;; esac
# keyfile values: reject ';' and '\' rather than escape them.
case $SSID$PSK in *';'*|*$'\\'*) echo "';' and '\\' are not supported by this script" >&2; exit 2 ;; esac

DIR=/etc/NetworkManager/system-connections
NAME=$SSID.nmconnection
UUID=$(cat /proc/sys/kernel/random/uuid)
keyfile() {
    cat <<EOF
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
cloned-mac-address=permanent

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
}

if [[ -n $ADB ]]; then
    A=(adb -s "$SERIAL")
    [[ $("${A[@]}" shell id -u | tr -d '\r') == 0 ]] || { echo "adb shell on $SERIAL is not root" >&2; exit 1; }
    # The device side reads the keyfile from stdin; only the path is on its command line.
    # adb joins exec-in's arguments into one remote shell command, and the
    # remote side is torn down when stdin closes, so exec-in only writes the
    # (0600) temporary file and a second call installs it.
    T="$DIR/.$NAME.tmp"
    keyfile | "${A[@]}" exec-in "umask 077; exec cat > \"$T\""
    PSK=""
    "${A[@]}" shell "test -s \"$T\" && chown root:root \"$T\" && chmod 600 \"$T\" && mv -f \"$T\" \"$DIR/$NAME\"" ||
        { echo "could not install $DIR/$NAME on $SERIAL" >&2; "${A[@]}" shell "rm -f \"$T\""; exit 1; }
    st=$("${A[@]}" shell "stat -c '%a %U:%G %s' '$DIR/$NAME'" | tr -d '\r')
    [[ ${st%% *} == 600 && $st == *" root:root "* ]] || { echo "unexpected mode/owner: $st" >&2; exit 1; }
    "${A[@]}" shell "nmcli connection reload && nmcli -g connection.id,connection.autoconnect,802-11-wireless.cloned-mac-address connection show '$SSID'" |
        tr -d '\r' | sed 's/^/inject-wifi: /'
    echo "inject-wifi: added $DIR/$NAME (0600 root:root) on $SERIAL"
    exit 0
fi

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

debugfs -R "stat $DIR" "$FS" 2>/dev/null | grep -q 'Type: directory' ||
    { echo "$DIR missing in image" >&2; exit 1; }

umask 077
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
keyfile > "$TMPD/conn"
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
