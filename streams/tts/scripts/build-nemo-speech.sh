#!/usr/bin/env bash
# Build NeMo-Speech.cpp (TTS only, with the Japanese and Mandarin front ends)
# from downloads/NeMo-Speech.cpp.
#
#   build-nemo-speech.sh native [BUILD_DIR] [extra cmake args...]   laptop build
#   build-nemo-speech.sh a53    [BUILD_DIR] [extra cmake args...]   device build
#
# The a53 build is cross-compiled with the asr stream's toolchain and sysroot
# (streams/asr/scripts/aarch64-static.cmake, streams/asr/work/sysroot):
# Cortex-A53, NEON, no dotprod/FP16 arithmetic, fully static. The build runs
# the aarch64 mecab-dict-index to compile the Open JTalk dictionary, so it
# needs qemu-aarch64 user-mode emulation on the build host.
# patches/0001 lets nemo_speech_tts be a static library for that.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
ASR=$(cd "$S/../asr" && pwd)
SRC=$S/downloads/NeMo-Speech.cpp
MODE=${1:?native or a53}; shift
B=${1:-$S/work/build-$MODE}; shift || true

# Local patches (patches/*.patch), applied once.
for p in "$S"/patches/*.patch; do
    if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p"
    elif ! git -C "$SRC" apply --check --reverse "$p" 2>/dev/null; then echo "patch $p does not apply" >&2; exit 1; fi
done

COMMON=(
    -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_LLAMAFILE=ON -DNEMO_SPEECH_GGML_PATCHED=ON
    -DNEMO_SPEECH_BUILD_ASR=OFF -DNEMO_SPEECH_BUILD_DIAR=OFF -DNEMO_SPEECH_BUILD_NMT=OFF
    -DNEMO_SPEECH_BUILD_TTS=ON -DNEMO_SPEECH_TTS_WITH_JA=ON -DNEMO_SPEECH_TTS_WITH_ZH=ON
    -DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF -DNEMO_SPEECH_BUILD_EXAMPLES=ON -DNEMO_SPEECH_BUILD_TOOLS=ON
)
case $MODE in
native)
    cmake -S "$SRC" -B "$B" "${COMMON[@]}" "$@" ;;
a53)
    [[ -d $ASR/work/sysroot ]] || { echo "run streams/asr/scripts/make-sysroot.sh first" >&2; exit 1; }
    command -v qemu-aarch64-static >/dev/null || command -v qemu-aarch64 >/dev/null ||
        { echo "needs qemu-aarch64 (user mode)" >&2; exit 1; }
    cmake -S "$SRC" -B "$B" "${COMMON[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$ASR/scripts/aarch64-static.cmake" -DTSV_SYSROOT="$ASR/work/sysroot" \
        -DCMAKE_CROSSCOMPILING_EMULATOR="$(command -v qemu-aarch64-static || command -v qemu-aarch64)" \
        -DBUILD_SHARED_LIBS=OFF -DNEMO_SPEECH_TTS_LIBRARY_TYPE=STATIC -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8-a -DGGML_OPENMP=OFF \
        "$@" ;;
*) echo "unknown mode $MODE" >&2; exit 1 ;;
esac
ninja -C "$B"
ls -la "$B"/bin
