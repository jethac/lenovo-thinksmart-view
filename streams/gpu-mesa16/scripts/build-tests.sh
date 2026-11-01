#!/usr/bin/env bash
# Cross-compile the gpu-mesa16 test programs for the tablet (aarch64) with host
# clang + lld against work/sysroot (see build-mesa.sh). They dlopen libEGL.so.1,
# so the Mesa they use is whatever LD_LIBRARY_PATH points at.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SR=$TOP/work/sysroot
OUT=$TOP/build
mkdir -p "$OUT/include"
cp -r /usr/include/EGL /usr/include/GLES3 /usr/include/KHR "$OUT/include/"
for t in ssbo-probe gles16; do
    [[ -f $TOP/src/$t.c ]] || continue
    clang --target=aarch64-linux-gnu --sysroot="$SR" -mcpu=cortex-a53 -O2 -Wall -Wextra \
        -Wno-unused-parameter -Wno-unused-function -Wno-missing-field-initializers \
        -isystem "$OUT/include" -fuse-ld=lld --rtlib=libgcc \
        -o "$OUT/$t" "$TOP/src/$t.c" -ldl -lm
    echo "built $OUT/$t"
done
