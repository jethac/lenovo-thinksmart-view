#!/usr/bin/env bash
# Run straylight-gpu's sg-bench on the tablet under the device lock, with the
# Mesa staged in /var/tmp/gpu-root (gpu-compute/scripts/install-mesa-disk.sh).
#   device-bench.sh TAG args...       env BIN (sg-bench; or sg-ubench, kokoro-gpu-check), SG_* passed through
# Output: results/bench-TAG-<date>.log (hangcheck count before and after).
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SV=${SV:-/home/jethac/Projects/straylight-voice}
A=(adb -s feb0bd1f028e4cb0)
R=/var/tmp/gpu-root
TAG=$1; shift
LOG=$TOP/results/bench-$TAG-$(date +%Y%m%d-%H%M).log
BIN=${BIN:-sg-bench}
"${A[@]}" push -q "$SV/out/gpu-aarch64/$BIN" /var/tmp/ </dev/null
ENVS="-E LD_LIBRARY_PATH=$R/usr/lib -E __EGL_VENDOR_LIBRARY_DIRS=$R/usr/share/glvnd/egl_vendor.d"
ENVS+=" -E LIBGL_DRIVERS_PATH=$R/usr/lib/dri -E GBM_BACKENDS_PATH=$R/usr/lib/gbm -E MESA_SHADER_CACHE_DIR=/var/tmp/sg-cache"
for v in SG_CONFIGS SG_MIN_TIME FD_MESA_DEBUG SG_UNROLL SG_NOFOLD SG_DIAG SG_TARGET_MS SG_L SG_G SG_BAND_MS KG_DUMP IR3_SHADER_DEBUG MESA_SHADER_CACHE_DISABLE; do [[ -n ${!v:-} ]] && ENVS+=" -E $v=\"${!v}\""; done
{
    echo "# $(date -Is) $BIN $*  SG_CONFIGS=${SG_CONFIGS:-}"
    "${A[@]}" shell 'echo "hangchecks before: $(dmesg | grep -c "hangcheck detected")  gpu faults: $(dmesg | grep -c "gpu fault")"; cat /sys/class/thermal/thermal_zone*/temp | tr "\n" " "; echo; uptime' </dev/null
    "${A[@]}" shell "timeout 1200 systemd-run --quiet --wait --pipe -p MemoryMax=500M -p WorkingDirectory=$R $ENVS /var/tmp/$BIN $*; rm -f /var/tmp/$BIN" </dev/null || echo "exit $?"
    "${A[@]}" shell 'echo "hangchecks after: $(dmesg | grep -c "hangcheck detected")  gpu faults: $(dmesg | grep -c "gpu fault")"; cat /sys/class/thermal/thermal_zone*/temp | tr "\n" " "; echo' </dev/null
} 2>&1 | tee "$LOG"
echo "log: $LOG"
