#!/usr/bin/env bash
# Run a command on the laptop against the host build of the patched Mesa with
# the freedreno noop drm-shim pretending to be an Adreno 510 (the shim has no 506; same a5xx compiler) (no GPU work is
# done; useful for compiling shaders and reading IR3_SHADER_DEBUG=disasm).
#   host-shim.sh CMD...
TOP=$(cd "$(dirname "$0")/.." && pwd)
I=$TOP/work/host-install
export LD_LIBRARY_PATH=$I/lib LD_PRELOAD=$I/lib/libfreedreno_noop_drm_shim.so
export FD_GPU_ID=${FD_GPU_ID:-510} MESA_SHADER_CACHE_DISABLE=true
export DRM_SHIM_DEBUG=${DRM_SHIM_DEBUG:-0}
exec "$@"
