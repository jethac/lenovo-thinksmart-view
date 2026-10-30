#!/bin/bash
# Install a kernel build on the running ThinkSmart View over adb (root), keeping
# the previous kernel, DTB, initramfs and modules so it can be put back.
#
#   kernel/deploy-to-device.sh [--reboot] [BUILD_DIR]     install (default build-7.3)
#   kernel/deploy-to-device.sh --rollback [--reboot]      put the previous kernel back
#
# Holds the device lock (see WORKSTREAMS.md) for the whole run, including the
# reboot wait. If the device does not come back after a reboot, stop and get
# the EDL recovery done (FLASHING.md); do not retry blindly.
set -euo pipefail
SELF=$(readlink -f "$0")
cd "$(dirname "$SELF")"
PROJ=$(cd .. && pwd)
LOCK=$PROJ/.device.lock
SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
SRC=${SRC:-linux-7.3}
DTB=apq8053-lenovo-cd-18781y.dtb
A=(adb -s "$SERIAL")

REBOOT=0 ROLLBACK=0 BUILD=build-7.3
for a in "$@"; do
  case $a in
    --reboot) REBOOT=1 ;;
    --rollback) ROLLBACK=1 ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) BUILD=$a ;;
  esac
done

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 1800 "$LOCK" "$SELF" "$@"
fi

dev() { "${A[@]}" shell "$@"; }
dev true >/dev/null 2>&1 || { echo "device $SERIAL not reachable over adb" >&2; exit 1; }
[[ $(dev id -u | tr -d '\r') == 0 ]] || { echo "adb shell is not root" >&2; exit 1; }

wait_back() {
  # adb reboot does not always reboot this device, and adb answering again
  # proves nothing, so compare boot IDs: success means a different boot.
  local before after
  before=$(dev cat /proc/sys/kernel/random/boot_id | tr -d '\r')
  echo "rebooting (boot $before); waiting up to 180 s for a new boot"
  dev systemctl reboot >/dev/null 2>&1 || "${A[@]}" reboot || true
  sleep 10
  for _ in $(seq 1 170); do
    after=$(dev cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
    if [[ -n $after && $after != "$before" ]]; then
      echo "back: boot $after, $(dev uname -r | tr -d '\r'), $(dev systemctl is-system-running | tr -d '\r')"
      return 0
    fi
    sleep 1
  done
  if [[ -n ${after:-} && $after == "$before" ]]; then
    echo "DEVICE DID NOT REBOOT (same boot ID $before). The new kernel is installed but not running." >&2
  else
    echo "DEVICE DID NOT COME BACK. Do not retry; recovery is EDL (FLASHING.md)." >&2
  fi
  return 1
}

if (( ROLLBACK )); then
  dev 'set -e; cd /boot
    for f in Image.gz initramfs-tsv.img kernel.release dtbs/qcom/'"$DTB"'; do
      [ -e "$f.prev" ] || { echo "no $f.prev to roll back to" >&2; exit 1; }
    done
    kv=$(cat kernel.release.prev)
    [ -f "/usr/lib/modules/$kv.prev.tar" ] && { rm -rf "/usr/lib/modules/$kv"; tar -C /usr/lib/modules -xf "/usr/lib/modules/$kv.prev.tar"; }
    for f in Image.gz initramfs-tsv.img kernel.release dtbs/qcom/'"$DTB"'; do mv -f "$f.prev" "$f"; done
    sync; echo "rolled back to $kv"'
  (( REBOOT )) && wait_back
  exit 0
fi

[[ -f $BUILD/arch/arm64/boot/Image.gz && -f $BUILD/arch/arm64/boot/dts/qcom/$DTB ]] ||
  { echo "no kernel build in kernel/$BUILD" >&2; exit 1; }
KVER=$(cat "$BUILD/include/config/kernel.release")
STAGE=$(mktemp -d "$PROJ/kernel/.deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

make -s -C "$SRC" O="../$BUILD" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$STAGE/mods" INSTALL_MOD_STRIP=1 modules_install
rm -f "$STAGE/mods/lib/modules/$KVER/build" "$STAGE/mods/lib/modules/$KVER/source"
tar -C "$STAGE/mods/lib/modules" -cf "$STAGE/modules.tar" "$KVER"
cp "$BUILD/arch/arm64/boot/Image.gz" "$STAGE/"
cp "$BUILD/arch/arm64/boot/dts/qcom/$DTB" "$STAGE/"
cp "$BUILD/.config" "$STAGE/config-$KVER"
printf '%s\n' "$KVER" > "$STAGE/kernel.release"
echo "installing $KVER from kernel/$BUILD"

"${A[@]}" shell 'rm -rf /tmp/tsv-deploy && mkdir -p /tmp/tsv-deploy'
"${A[@]}" push -q "$STAGE/modules.tar" "$STAGE/Image.gz" "$STAGE/$DTB" "$STAGE/config-$KVER" "$STAGE/kernel.release" /tmp/tsv-deploy/
dev 'set -e; cd /boot; S=/tmp/tsv-deploy
  old=$(cat kernel.release 2>/dev/null || uname -r)
  for f in Image.gz initramfs-tsv.img kernel.release dtbs/qcom/'"$DTB"'; do cp -a "$f" "$f.prev"; done
  [ -d "/usr/lib/modules/$old" ] && tar -C /usr/lib/modules -cf "/usr/lib/modules/$old.prev.tar" "$old"
  rm -rf "/usr/lib/modules/'"$KVER"'"
  tar -C /usr/lib/modules -xf $S/modules.tar
  depmod '"$KVER"'
  cp $S/Image.gz Image.gz; cp $S/'"$DTB"' dtbs/qcom/'"$DTB"'
  cp $S/config-'"$KVER"' .; cp $S/kernel.release kernel.release
  mkinitcpio -P >/tmp/tsv-deploy/mkinitcpio.log 2>&1 || { cat /tmp/tsv-deploy/mkinitcpio.log; exit 1; }
  for p in hooks/tsv-subpart hooks/plymouth msm.ko; do lsinitcpio initramfs-tsv.img | grep -q "$p" || { echo "initramfs is missing $p" >&2; exit 1; }; done
  sync; rm -rf $S; echo "installed '"$KVER"' (previous kept as *.prev)"'
(( REBOOT )) && wait_back
exit 0
