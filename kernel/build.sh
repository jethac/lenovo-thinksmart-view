#!/bin/bash
# Build the msm8953-mainline kernel for the ThinkSmart View CD-18781Y.
# Default tree is barni2000/7.3/develop (linux-7.3); SRC=linux OUT=build builds the 7.1.3 tree.
set -euo pipefail
cd "$(dirname "$0")"
SRC=${SRC:-linux-7.3}
OUT=${OUT:-build-7.3}
K="make -C $SRC O=../$OUT ARCH=arm64 LLVM=1 -j$(nproc)"
mkdir -p $OUT
# Apply our patches to a pristine tree on every build: the accepted series in
# kernel/patches/, then a workstream's work in progress from $EXTRA_PATCHES
# (a directory, e.g. patches-wip/wifi), in name order. Resetting first means a
# patch is never applied twice or guessed at; build output lives in $OUT, outside
# the tree, so it survives the reset.
git -C $SRC reset -q --hard
git -C $SRC clean -q -fd
for p in patches/*.patch ${EXTRA_PATCHES:+$EXTRA_PATCHES/*.patch}; do
  [ -e "$p" ] || continue
  git -C $SRC apply "../$p" || { echo "PATCH DOES NOT APPLY: $p" >&2; exit 1; }
  echo "applied $p"
done
cp config/lenovo-cd-18781y.config $SRC/arch/arm64/configs/lenovo-cd-18781y.config
$K defconfig msm8953.config no-unused-drivers.config lenovo-cd-18781y.config
# Fragments can be silently overridden; show what did not stick.
while IFS= read -r line; do
  case "$line" in CONFIG_*=*) grep -qxF "$line" $OUT/.config || echo "NOT SET: $line";; esac
done < config/lenovo-cd-18781y.config
$K Image.gz dtbs modules
ls -la $OUT/arch/arm64/boot/Image.gz $OUT/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb
