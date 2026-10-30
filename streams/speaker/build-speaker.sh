#!/bin/bash
# Build kernel/build-speaker from kernel/wt-speaker: the accepted series in
# kernel/patches/, then kernel/patches-wip/speaker/, configured with the
# baseline fragments plus the stream-local kernel/config/wip-speaker.config.
# Same steps as kernel/build.sh, with one more config fragment.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../../kernel"
SRC=wt-speaker OUT=build-speaker
K="make -C $SRC O=../$OUT ARCH=arm64 LLVM=1 -j$(nproc)"
mkdir -p $OUT
for p in patches/*.patch patches-wip/speaker/*.patch; do
  [ -e "$p" ] || continue
  if git -C $SRC apply --check "../$p" 2>/dev/null; then git -C $SRC apply "../$p" && echo "applied $p"
  elif git -C $SRC apply --check -R "../$p" 2>/dev/null; then echo "already applied $p"
  else echo "PATCH DOES NOT APPLY: $p" >&2; exit 1; fi
done
cp config/lenovo-cd-18781y.config $SRC/arch/arm64/configs/lenovo-cd-18781y.config
cp config/wip-speaker.config $SRC/arch/arm64/configs/wip-speaker.config
$K defconfig msm8953.config no-unused-drivers.config lenovo-cd-18781y.config wip-speaker.config
for f in config/lenovo-cd-18781y.config config/wip-speaker.config; do
  while IFS= read -r line; do
    case "$line" in CONFIG_*=*) grep -qxF "$line" $OUT/.config || echo "NOT SET: $line";; esac
  done < "$f"
done
$K Image.gz dtbs modules
ls -la $OUT/arch/arm64/boot/Image.gz $OUT/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb
