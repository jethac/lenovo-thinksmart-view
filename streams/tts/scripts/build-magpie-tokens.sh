#!/usr/bin/env bash
# Build src/magpie-tokens.cpp against an existing NeMo-Speech.cpp build:
#   build-magpie-tokens.sh native   -> work/magpie-tokens-native (links work/build-native)
#   build-magpie-tokens.sh a53      -> work/magpie-tokens-a53 (static, links work/build-a53)
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
N=$S/downloads/NeMo-Speech.cpp
case ${1:?native or a53} in
native)
    B=$S/work/build-native
    clang++ -std=c++17 -O2 -I"$N/src" -I"$N/include" "$S/src/magpie-tokens.cpp" -o "$S/work/magpie-tokens-native" \
        -L"$B/bin" -lnemo_speech_tts -Wl,-rpath,"$B/bin" ;;
a53)
    B=$S/work/build-a53
    clang++ --target=aarch64-linux-gnu --sysroot="$S/../asr/work/sysroot" -mcpu=cortex-a53 -O2 -std=c++17 \
        -fuse-ld=lld -static --rtlib=libgcc -I"$N/src" -I"$N/include" "$S/src/magpie-tokens.cpp" -o "$S/work/magpie-tokens-a53" \
        -Wl,--start-group "$B"/src/tts/magpietts/libnemo_speech_tts.a "$B"/src/tts/tokenizer/libnemo_speech_openjtalk_frontend.a \
        "$B"/src/tts/preproc/libnemo_speech_tts_preproc.a "$B"/src/common/libnemo_speech_common.a \
        "$B"/src/runtime/ggml/libnemo_speech_runtime_ggml.a "$B"/ggml/src/libggml.a "$B"/ggml/src/libggml-cpu.a \
        "$B"/ggml/src/libggml-base.a -Wl,--end-group -lpthread -ldl -lm ;;
esac
