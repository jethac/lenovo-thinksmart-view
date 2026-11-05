#!/usr/bin/env bash
# Cross-build a small ffmpeg for the tablet's private test prefix: V4L2 M2M
# (Venus) H.264/HEVC decode and H.264 encode, the native H.264/HEVC decoders
# and libx264 for the CPU comparison, raw video and MP4/MKV/Annex B I/O.
#
#   streams/video-codec/build-ffmpeg.sh [OUT]     default OUT = streams/video-codec/work/ffmpeg
#
# Sources (downloads/, not in git): FFmpeg tag n8.1.3 (commit 1041abdc962f)
# cloned from git@github.com:FFmpeg/FFmpeg.git; libx264 headers and library
# from the Arch Linux ARM x264 0.165.r3222 package (SHA-256 ef95679c...f70,
# from the extra.db the camera stream downloaded). Compiler: clang + ld.lld
# against the asr stream's aarch64 glibc sysroot.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
SYSROOT=${SYSROOT:-$TOP/streams/asr/work/sysroot}
SRC=$HERE/downloads/ffmpeg-n8.1.3
OUT=${1:-$HERE/work/ffmpeg}
X264PKG=$HERE/downloads/x264-0.165.pkg.tar.xz

[[ $(git -C "$SRC" rev-parse HEAD) == 1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7 ]] || { echo "unexpected ffmpeg source" >&2; exit 1; }
# test hook: TSV_V4L2_DECODE_ORDER=1 sets the V4L2 display delay to 0 (decode order)
git -C "$SRC" checkout -q -- .
git -C "$SRC" apply "$HERE/ffmpeg-decode-order-test.patch"
# fix: keep a pending packet while the capture queue is not set up (for upstream)
git -C "$SRC" apply "$HERE/ffmpeg-v4l2-keep-pending-packet.patch"
echo "ef95679c4ecf842fd08d1e49c61977c39fb38f0c2c67384130e9aba860229f70  $X264PKG" | sha256sum -c --quiet
mkdir -p "$OUT/deps" "$OUT/build"
bsdtar -xf "$X264PKG" -C "$OUT/deps" usr/include usr/lib
CC="clang --target=aarch64-linux-gnu --sysroot=$SYSROOT -mcpu=cortex-a53"
cd "$OUT/build"
export PKG_CONFIG_LIBDIR=$OUT/deps/usr/lib/pkgconfig PKG_CONFIG_SYSROOT_DIR=$OUT/deps PKG_CONFIG_PATH=
"$SRC/configure" --prefix=/ --enable-cross-compile --arch=aarch64 --target-os=linux \
  --cc="$CC" --cxx="clang++ --target=aarch64-linux-gnu --sysroot=$SYSROOT" \
  --ld="$CC -fuse-ld=lld" --ar=llvm-ar --nm=llvm-nm --ranlib=llvm-ranlib --strip=llvm-strip \
  --pkg-config=pkg-config --extra-cflags="-I$OUT/deps/usr/include" \
  --extra-ldflags="-L$OUT/deps/usr/lib -Wl,--allow-shlib-undefined" \
  --enable-gpl --enable-libx264 --enable-v4l2-m2m \
  --disable-everything --disable-doc --disable-ffplay --disable-network --disable-autodetect \
  --enable-ffmpeg --enable-ffprobe \
  --enable-decoder=h264,hevc,h264_v4l2m2m,hevc_v4l2m2m,rawvideo,mjpeg \
  --enable-encoder=h264_v4l2m2m,libx264,rawvideo,wrapped_avframe \
  --enable-parser=h264,hevc,mjpeg --enable-demuxer=h264,hevc,mov,matroska,rawvideo,mjpeg \
  --enable-muxer=mp4,matroska,h264,hevc,rawvideo,null,framecrc,framemd5 \
  --enable-protocol=file,pipe,fd --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,null \
  --enable-filter=scale,format,null,framestep,select,setpts >/dev/null
make -j"$(nproc)" >/dev/null
llvm-strip -o "$OUT/ffmpeg" ffmpeg
llvm-strip -o "$OUT/ffprobe" ffprobe
cp -L "$OUT/deps/usr/lib/libx264.so.165" "$OUT/"
ls -la "$OUT/ffmpeg" "$OUT/ffprobe" "$OUT/libx264.so.165"
