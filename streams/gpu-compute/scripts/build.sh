#!/usr/bin/env bash
# Cross-compile gles-sgemm for the tablet (aarch64, Cortex-A53) with host clang
# and lld against the sysroot from streams/asr/scripts/make-sysroot.sh.
# Linked dynamically (it dlopens the device's libEGL.so.1, which needs the
# device's own glibc); only glibc symbols are linked. The Khronos headers
# (EGL, GLES3, KHR) are copied from the laptop's /usr/include.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
SYSROOT=${TSV_SYSROOT:-$TOP/../asr/work/sysroot}
OUT=$TOP/build
mkdir -p "$OUT/include"
cp -r /usr/include/EGL /usr/include/GLES3 /usr/include/KHR "$OUT/include/"
clang --target=aarch64-linux-gnu --sysroot="$SYSROOT" -mcpu=cortex-a53 -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
    -isystem "$OUT/include" -fuse-ld=lld --rtlib=libgcc \
    -o "$OUT/gles-sgemm" "$TOP/src/gles-sgemm.c" -ldl -lm
echo "built $OUT/gles-sgemm"

# CPU baseline against the aarch64 ggml static libraries from the asr stream's
# transcribe.cpp build (streams/asr/scripts/build-transcribe.sh), fully static.
ASR=$TOP/../asr
GGML_BUILD=${GGML_BUILD:-$ASR/work/build-a53/ggml/src}
GGML_INC=$ASR/downloads/transcribe.cpp/ggml/include
if [[ -f $GGML_BUILD/libggml-cpu.a ]]; then
    clang --target=aarch64-linux-gnu --sysroot="$SYSROOT" -mcpu=cortex-a53 -O2 -Wall -I"$GGML_INC" \
        -c -o "$OUT/cpu-gemm.o" "$TOP/src/cpu-gemm.c"
    clang++ --target=aarch64-linux-gnu --sysroot="$SYSROOT" -fuse-ld=lld -static --rtlib=libgcc \
        -o "$OUT/cpu-gemm" "$OUT/cpu-gemm.o" "$GGML_BUILD/libggml.a" "$GGML_BUILD/libggml-cpu.a" \
        "$GGML_BUILD/libggml-base.a" -lpthread -lm
    echo "built $OUT/cpu-gemm"
fi
