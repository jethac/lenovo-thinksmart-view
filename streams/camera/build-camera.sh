#!/bin/bash
# Build the camera stream kernel: kernel/build.sh's steps on the wt-camera
# worktree, with kernel/config/wip-camera.config added after the board config.
# The worktree carries the accepted kernel/patches series as its base commit;
# the stream's work is applied from kernel/patches-wip/camera/.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../../kernel"
SRC=wt-camera OUT=build-camera
K="make -C $SRC O=../$OUT ARCH=arm64 LLVM=1 -j$(nproc)"
mkdir -p $OUT
# The accepted series is the worktree's base commit; check it against that
# commit (the stream's own edits sit next to it in the same files).
IDX=$(mktemp); trap 'rm -f "$IDX"' EXIT
GIT_INDEX_FILE=$IDX git -C $SRC read-tree HEAD
for p in patches/*.patch; do
  GIT_INDEX_FILE=$IDX git -C $SRC apply --cached --check -R "../$p" 2>/dev/null \
    || { echo "accepted patch missing from $SRC base commit: $p (rebase ws/camera)" >&2; exit 1; }
done
for p in patches-wip/camera/*.patch; do
  [ -e "$p" ] || continue
  if git -C $SRC apply --check "../$p" 2>/dev/null; then git -C $SRC apply "../$p" && echo "applied $p"
  elif git -C $SRC apply --check -R "../$p" 2>/dev/null; then echo "already applied $p"
  else echo "PATCH DOES NOT APPLY: $p" >&2; exit 1; fi
done
cp config/lenovo-cd-18781y.config $SRC/arch/arm64/configs/lenovo-cd-18781y.config
cp config/wip-camera.config $SRC/arch/arm64/configs/wip-camera.config
$K defconfig msm8953.config no-unused-drivers.config lenovo-cd-18781y.config wip-camera.config
for f in config/lenovo-cd-18781y.config config/wip-camera.config; do
  while IFS= read -r line; do
    case "$line" in CONFIG_*=*) grep -qxF "$line" $OUT/.config || echo "NOT SET: $line";; esac
  done < $f
done
$K Image.gz dtbs modules
ls -la $OUT/arch/arm64/boot/Image.gz $OUT/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb
