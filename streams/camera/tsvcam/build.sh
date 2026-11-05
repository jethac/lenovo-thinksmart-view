#!/usr/bin/env bash
# Cross-build libtsvcam (static and shared) and the tsvcam tool for the tablet.
#
#   streams/camera/tsvcam/build.sh [OUT]     default OUT = streams/camera/work/tsvcam
#
# Compiler: clang + ld.lld against the aarch64 glibc sysroot of the asr stream
# (streams/asr/scripts/make-sysroot.sh). libjpeg-turbo headers and the link
# library come from the Arch Linux ARM package the camera stream downloaded
# (checked against downloads/pkgs/SHA256SUMS); the tablet already has it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STREAM=$(cd "$HERE/.." && pwd)
TOP=$(cd "$STREAM/../.." && pwd)
SYSROOT=${SYSROOT:-$TOP/streams/asr/work/sysroot}
OUT=${1:-$STREAM/work/tsvcam}
PKG=$STREAM/downloads/pkgs/libjpeg-turbo-3.2.0-2-aarch64.pkg.tar.xz

[[ -f $SYSROOT/usr/lib/aarch64-linux-gnu/libc.so.6 ]] || { echo "no sysroot at $SYSROOT" >&2; exit 1; }
(cd "$STREAM/downloads" && grep " pkgs/$(basename "$PKG")\$" pkgs/SHA256SUMS | sha256sum -c --quiet)
mkdir -p "$OUT/jpeg"
bsdtar -xf "$PKG" -C "$OUT/jpeg" usr/include usr/lib

CC=(clang --target=aarch64-linux-gnu --sysroot="$SYSROOT" -mcpu=cortex-a53 -O2 -g0
    -Wall -Wextra -Wno-unused-parameter -fPIC -I"$HERE" -I"$OUT/jpeg/usr/include")
LD=(-fuse-ld=lld -L"$OUT/jpeg/usr/lib" -Wl,--allow-shlib-undefined)
"${CC[@]}" -c "$HERE/tsvcam.c" -o "$OUT/tsvcam.o"
"${CC[@]}" -c "$HERE/tsvcam-clip.c" -o "$OUT/tsvcam-clip.o"
"${CC[@]}" -c "$HERE/tsvsel.c" -o "$OUT/tsvsel.o"
"${CC[@]}" -c "$HERE/mp4mux.c" -o "$OUT/mp4mux.o"
llvm-ar rcs "$OUT/libtsvcam.a" "$OUT/tsvcam.o" "$OUT/tsvcam-clip.o" "$OUT/tsvsel.o" "$OUT/mp4mux.o"
"${CC[@]}" -shared -Wl,-soname,libtsvcam.so.0 "${LD[@]}" -o "$OUT/libtsvcam.so.0" "$OUT/tsvcam.o" "$OUT/tsvcam-clip.o" "$OUT/tsvsel.o" "$OUT/mp4mux.o" -lturbojpeg -lm
"${CC[@]}" "${LD[@]}" -o "$OUT/tsvcam" "$HERE/tsvcam-cli.c" "$OUT/libtsvcam.a" -lturbojpeg -lm
llvm-strip "$OUT/tsvcam" "$OUT/libtsvcam.so.0"
ls -la "$OUT/tsvcam" "$OUT/libtsvcam.so.0" "$OUT/libtsvcam.a"
