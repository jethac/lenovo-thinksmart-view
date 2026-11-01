#!/usr/bin/env bash
# ir3 statistics of the kernels sg-bench builds (IR3_SHADER_DEBUG=disasm), under the lock.
#   device-disasm.sh sg-bench-args...       (SG_CONFIGS passed through)
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
SV=${SV:-/home/jethac/Projects/straylight-voice}
A=(adb -s feb0bd1f028e4cb0)
R=/var/tmp/gpu-root
"${A[@]}" push -q "$SV/out/gpu-aarch64/sg-bench" "$R/" </dev/null
ENVS="-E LD_LIBRARY_PATH=$R/usr/lib -E __EGL_VENDOR_LIBRARY_DIRS=$R/usr/share/glvnd/egl_vendor.d -E LIBGL_DRIVERS_PATH=$R/usr/lib/dri"
ENVS+=" -E FD_MESA_DEBUG=sysmem ${SG_UNROLL:+-E SG_UNROLL=$SG_UNROLL} -E IR3_SHADER_DEBUG=disasm -E MESA_SHADER_CACHE_DISABLE=true -E SG_MIN_TIME=0.01 -E SG_DRY=1"
[[ -n ${SG_CONFIGS:-} ]] && ENVS+=" -E SG_CONFIGS=\"$SG_CONFIGS\""
"${A[@]}" shell "timeout 120 systemd-run --quiet --wait --pipe -p MemoryMax=500M $ENVS $R/sg-bench $* 2>&1" </dev/null
