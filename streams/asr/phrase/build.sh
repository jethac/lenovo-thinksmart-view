#!/usr/bin/env bash
# Build phrase-stream against a pinned snapshot of transcribe.cpp.
#
#   build.sh [a53|native]
#
# The snapshot is the pinned commit of downloads/transcribe.cpp exported with
# `git archive` into work/phrase-src/ plus patches/0001 (quantised conv stem),
# so work in progress in that checkout never leaks into this build.
# a53: static cross-build for the ThinkSmart View (needs work/sysroot from
# scripts/make-sysroot.sh), into work/build-phrase-a53. native: laptop build
# for transcript checks, into work/build-phrase-native.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
TARGET=${1:-a53}
COMMIT=5700f127e38dd53c4735ea23ef743b4b538eacd4
SRC=$S/work/phrase-src/transcribe.cpp
STAMP=$S/work/phrase-src/STAMP
WANT="$COMMIT $(sha256sum "$S"/patches/*.patch | sha256sum | cut -c1-16)"
if [[ ! -f $STAMP || $(cat "$STAMP") != "$WANT" ]]; then
    rm -rf "$S/work/phrase-src"; mkdir -p "$SRC"
    git -C "$S/downloads/transcribe.cpp" archive "$COMMIT" | tar -x -C "$SRC"
    # patch(1), not git apply: inside the project repo git apply would silently
    # skip paths outside the repo index.
    for p in "$S"/patches/*.patch; do patch -d "$SRC" -p1 -s --no-backup-if-mismatch < "$p"; done
    echo "$WANT" > "$STAMP"
fi
case $TARGET in
a53)
    B=$S/work/build-phrase-a53
    cmake -S "$HERE" -B "$B" -G Ninja -DTRANSCRIBE_SRC="$SRC" \
        -DCMAKE_TOOLCHAIN_FILE="$S/scripts/aarch64-static.cmake" -DTSV_SYSROOT="$S/work/sysroot" \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8-a -DGGML_OPENMP=OFF \
        -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF
    ninja -C "$B" phrase-stream
    llvm-strip "$B/bin/phrase-stream" ;;
native)
    B=$S/work/build-phrase-native
    cmake -S "$HERE" -B "$B" -G Ninja -DTRANSCRIBE_SRC="$SRC" -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=ON -DGGML_OPENMP=OFF -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF
    ninja -C "$B" phrase-stream ;;
*) echo "usage: $0 [a53|native]" >&2; exit 2 ;;
esac
ls -la "$B/bin/phrase-stream"
