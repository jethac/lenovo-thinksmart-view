#!/bin/bash
# Build kernel/build-wifi from kernel/wt-wifi: the accepted series in
# kernel/patches/, then kernel/patches-wip/wifi/, configured with the baseline
# fragments plus the stream-local kernel/config/wip-wifi.config.
# Same steps as kernel/build.sh, with one more config fragment.
#   WIP_CONFIG=0 streams/wifi/build-wifi.sh   builds without the fragment
set -euo pipefail
cd "$(dirname "$0")/../../kernel"
SRC=wt-wifi OUT=build-wifi  # log: run as  build-wifi.sh > kernel/build-wifi.log 2>&1
K="make -C $SRC O=../$OUT ARCH=arm64 LLVM=1 -j$(nproc)"
mkdir -p $OUT
for p in patches/*.patch patches-wip/wifi/*.patch; do
  [ -e "$p" ] || continue
  if git -C $SRC apply --check "../$p" 2>/dev/null; then git -C $SRC apply "../$p" && echo "applied $p"
  elif git -C $SRC apply --check -R "../$p" 2>/dev/null; then echo "already applied $p"
  else echo "PATCH DOES NOT APPLY: $p" >&2; exit 1; fi
done
cp config/lenovo-cd-18781y.config $SRC/arch/arm64/configs/lenovo-cd-18781y.config
FRAGS="defconfig msm8953.config no-unused-drivers.config lenovo-cd-18781y.config"
if [[ ${WIP_CONFIG:-1} == 1 ]]; then
  cp config/wip-wifi.config $SRC/arch/arm64/configs/wip-wifi.config
  FRAGS="$FRAGS wip-wifi.config"
fi
$K $FRAGS
for f in config/lenovo-cd-18781y.config $([[ ${WIP_CONFIG:-1} == 1 ]] && echo config/wip-wifi.config); do
  while IFS= read -r line; do
    case "$line" in CONFIG_*=*) grep -qxF "$line" $OUT/.config || echo "NOT SET: $line";; esac
  done < "$f"
done
$K Image.gz dtbs modules
ls -la $OUT/arch/arm64/boot/Image.gz $OUT/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb
