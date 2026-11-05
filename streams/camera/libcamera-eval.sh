#!/bin/sh
# Run on the device (root, under the device lock): libcamera 0.7.2 (Arch Linux
# ARM packages, unpacked into /var/tmp/tsv-camcodec/lc) on the S5KC505A with
# the simple pipeline handler and the CPU software ISP. libEGL, libGLESv2 and
# libSDL2 are stubs there (the image has no Mesa or SDL), so only
# LIBCAMERA_SOFTISP_MODE=cpu can work. Frames go to $OUT (captures).
set -u
P=/var/tmp/tsv-camcodec
OUT=$P/out/libcamera
rm -rf $OUT; mkdir -p $OUT
run() { systemd-run --wait --pipe --collect -p MemoryMax=300M -E LIBCAMERA_LOG_LEVELS="${LOGL:-*:WARN}" \
	-E LD_LIBRARY_PATH=$P/lc/lib -E LIBCAMERA_IPA_MODULE_PATH=$P/lc/lib/ipa \
	-E LIBCAMERA_IPA_PROXY_PATH=$P/lc/libexec -E LIBCAMERA_IPA_CONFIG_PATH=$P/lc/share/libcamera/ipa \
	-E LIBCAMERA_SOFTISP_MODE=cpu "$@" 2>&1; }
$P/bin/tsvcam cover || exit 3
ls -la /dev/dma_heap /dev/udmabuf 2>&1
echo "== cam -l"; LOGL='*:INFO' run $P/lc/bin/cam -l | tail -30
echo "== cam -c1 -I"; run $P/lc/bin/cam -c1 -I | tail -30
echo "== 1304x980 RGB888, 60 frames"
run $P/lc/bin/cam -c1 -s width=1304,height=980,pixelformat=RGB888 -C60 -F$OUT/f-#.rgb | tail -12
ls $OUT | head -3; ls $OUT | wc -l
echo "== 2608x1960 RGB888, 10 frames"
run $P/lc/bin/cam -c1 -s width=2608,height=1960,pixelformat=RGB888 -C10 | tail -8
ls -la $OUT | tail -3
