#!/usr/bin/env bash
# Install Mesa (freedreno) and its missing dependencies on the tablet, offline,
# into a tmpfs root instead of /. The real root has about 48 MiB free and Mesa
# needs about 250 MiB installed (llvm-libs alone is 164 MiB), so it cannot go
# into / until stage-b grows the root partition.
#
# pacman -U verifies every package signature against the device keyring
# (/etc/pacman.d/gnupg, SigLevel Required). Dependencies already on the device
# (libdrm, libx11, expat, zstd, ...) are used from /usr/lib; -dd skips the
# dependency check that the separate root database cannot satisfy.
#
#   install-mesa-tmpfs.sh mesa     -> /tmp/gpu-root (Mesa, mesa-utils)
#   install-mesa-tmpfs.sh opencl   -> /tmp/ocl-root (opencl-mesa, ocl-icd, clinfo)
#
# Run on the laptop; takes the device lock. On the device: . /tmp/gpu-root/env.sh
# Gone after a reboot; remove earlier with: rm -rf /tmp/gpu-root /tmp/ocl-root
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
DL=$HERE/../downloads/alarm
A=(adb -s feb0bd1f028e4cb0)
MESA=(libglvnd libxshmfence libxxf86vm llvm-libs lm_sensors spirv-tools default-cursors
      wayland mesa libdecor libxkbcommon-x11 vulkan-icd-loader mesa-utils)
OCL=(clang-libs spirv-llvm-translator libclc opencl-mesa ocl-icd clinfo)
case ${1:-mesa} in
    mesa) PK=("${MESA[@]}"); R=/tmp/gpu-root ;;
    opencl) PK=("${OCL[@]}"); R=/tmp/ocl-root ;;
    *) echo "usage: $0 mesa|opencl" >&2; exit 2 ;;
esac
# Signatures are checked against the device clock; it has no NTP.
"${A[@]}" shell "date -s @$(date +%s) >/dev/null; mkdir -p /tmp/gpu-pkgs $R/var/lib/pacman /tmp/gpu-empty-hooks" </dev/null
args=()
for p in "${PK[@]}"; do
    f=$(cd "$DL" && ls | grep -E "^${p}-[0-9:]+[^-]*-[^-]+-(aarch64|any)\.pkg\.tar\.xz$")
    "${A[@]}" push -q "$DL/$f" "$DL/$f.sig" /tmp/gpu-pkgs/ </dev/null
    args+=("/tmp/gpu-pkgs/$f")
done
"${A[@]}" shell "pacman -U --noconfirm -dd --root $R --dbpath $R/var/lib/pacman \
    --cachedir /tmp/gpu-pkgs --hookdir /tmp/gpu-empty-hooks --logfile $R/pacman.log ${args[*]}" </dev/null
"${A[@]}" shell "rm -rf /tmp/gpu-pkgs /tmp/gpu-empty-hooks; cat > /tmp/gpu-root/env.sh" <<'ENV'
# Source me: use the Mesa userspace installed under /tmp/gpu-root (and /tmp/ocl-root).
export LD_LIBRARY_PATH=/tmp/gpu-root/usr/lib:/tmp/ocl-root/usr/lib
export PATH=/tmp/gpu-root/usr/bin:/tmp/ocl-root/usr/bin:$PATH
export __EGL_VENDOR_LIBRARY_DIRS=/tmp/gpu-root/usr/share/glvnd/egl_vendor.d
export LIBGL_DRIVERS_PATH=/tmp/gpu-root/usr/lib/dri
export GBM_BACKENDS_PATH=/tmp/gpu-root/usr/lib/gbm
export OCL_ICD_VENDORS=/tmp/ocl-root/etc/OpenCL/vendors
ENV
"${A[@]}" shell "du -sh $R; df -h /tmp | tail -1; date" </dev/null
