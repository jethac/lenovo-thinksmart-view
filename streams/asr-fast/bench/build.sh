#!/usr/bin/env bash
# Build sla-bench against straylight-voice's recogniser library.
#
#   bench/build.sh [aarch64|native]
#
# STRAYLIGHT_VOICE (default: ../straylight-voice next to this project; set it
# to a worktree to test a branch) is a checkout whose listen/asr/build.sh has
# been run for the target: the archives in out/listen/asr-<target>/ are
# linked as they are linked into straylight-listen. aarch64: glibc and
# libdl dynamic (the sherpa-onnx library is opened at run time), the C++
# runtime static, as straylight-listen. Output: work/build-bench-<target>/sla-bench.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
T=${1:-aarch64}
SV=${STRAYLIGHT_VOICE:-$(cd "$S/../../.." && pwd)/straylight-voice}
L=$SV/out/listen/asr-$T
[[ -f $L/libstraylight_asr.a ]] || { echo "no $L/libstraylight_asr.a: run $SV/listen/asr/build.sh $T" >&2; exit 1; }
B=$S/work/build-bench-$T; mkdir -p "$B"
LIBS=("$L"/libstraylight_asr.a "$L"/libtranscribe.a "$L"/libggml.a "$L"/libggml-cpu.a "$L"/libggml-base.a)
case $T in
aarch64)
    SR=${STRAYLIGHT_SYSROOT:-$SV/sysroot}
    GCC=$(ls -d "$SR"/usr/lib/gcc/aarch64-linux-gnu/* | head -1)
    clang++ --target=aarch64-linux-gnu --sysroot="$SR" -mcpu=cortex-a53 -O2 -std=c++17 -fuse-ld=lld --rtlib=libgcc \
        -I"$SV/listen/asr" "$HERE/sla-bench.cpp" "${LIBS[@]}" \
        -L"$GCC" -Wl,-Bstatic -lstdc++ -Wl,-Bdynamic -lm -ldl -lpthread -o "$B/sla-bench"
    llvm-strip "$B/sla-bench" ;;
native)
    clang++ -O2 -std=c++17 -I"$SV/listen/asr" "$HERE/sla-bench.cpp" "${LIBS[@]}" -lstdc++ -lm -ldl -lpthread \
        -o "$B/sla-bench" ;;
*) echo "usage: $0 [aarch64|native]" >&2; exit 2 ;;
esac
ls -la "$B/sla-bench"
