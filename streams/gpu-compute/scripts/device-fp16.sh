#!/usr/bin/env bash
# FP16 data-path experiment (gles-fp16) on the tablet, under the device lock.
# Needs Mesa staged by install-mesa-disk.sh and build/gles-fp16 from build.sh.
#   device-fp16.sh [M K N [kernel...]]     default: 1024^3 and a vocoder-shaped conv GEMM
# Output: results/fp16-<date>.log
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
R=/var/tmp/gpu-root
LOG=$TOP/results/fp16-$(date +%Y%m%d-%H%M).log
"${A[@]}" push -q "$TOP/build/gles-fp16" "$R/" </dev/null
ENVS="-E LD_LIBRARY_PATH=$R/usr/lib -E __EGL_VENDOR_LIBRARY_DIRS=$R/usr/share/glvnd/egl_vendor.d"
ENVS+=" -E LIBGL_DRIVERS_PATH=$R/usr/lib/dri -E GBM_BACKENDS_PATH=$R/usr/lib/gbm ${KC:+-E KC=$KC} ${CHUNK:+-E CHUNK=$CHUNK}"
run() {
    "${A[@]}" shell "timeout 900 systemd-run --quiet --wait --pipe -p MemoryMax=400M -p WorkingDirectory=$R $ENVS $R/gles-fp16 bench $*" </dev/null
}
{
    if (($#)); then
        run "$@"
    else
        run 1024 1024 1024
        run 512 3584 4096   # conv1d 512 -> 512 channels, kernel 7, 4096 samples, as im2col GEMM
    fi
    "${A[@]}" shell 'echo "gpu faults/hangchecks in dmesg: $(dmesg | grep -cE "gpu fault|hangcheck")"' </dev/null
} 2>&1 | tee "$LOG"
echo "log: $LOG"
