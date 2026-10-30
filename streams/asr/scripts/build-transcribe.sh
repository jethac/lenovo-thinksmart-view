#!/usr/bin/env bash
# Cross-build transcribe.cpp (and its vendored ggml) for the ThinkSmart View:
# aarch64, Cortex-A53, NEON only, fully static. Source in downloads/transcribe.cpp.
#
#   build-transcribe.sh [BUILD_DIR] [extra cmake args...]
#
# Needs scripts/make-sysroot.sh to have been run (work/sysroot).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
B=${1:-$S/work/build-a53}; shift || true
export TSV_SYSROOT=$S/work/sysroot
cmake -S "$S/downloads/transcribe.cpp" -B "$B" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/aarch64-static.cmake" -DTSV_SYSROOT="$S/work/sysroot" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8-a -DGGML_OPENMP=OFF \
    -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_TOOLS=ON \
    "$@"
ninja -C "$B" transcribe-cli transcribe-bench transcribe-quantize
llvm-strip "$B"/bin/transcribe-{cli,bench,quantize}
ls -la "$B"/bin/transcribe-{cli,bench,quantize}
