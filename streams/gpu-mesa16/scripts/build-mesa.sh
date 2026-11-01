#!/usr/bin/env bash
# Cross-compile Mesa (freedreno Gallium + ir3, EGL, GLES) for the tablet
# (aarch64, Cortex-A53) with host clang + lld, with the patches in
# streams/gpu-mesa16/patches/ applied, into a separate prefix (/opt/mesa-16bit).
#
#   build-mesa.sh [--stock|--host] [--dev] [--clean]
#
#   --stock  build the unpatched tree into work/build-stock (prefix /opt/mesa-stock)
#   --host   native x86_64 build of the patched tree with the freedreno drm-shim
#            (work/host-install), to compile shaders for FD_GPU_ID=506 on the laptop
#   --dev    build work/src-16bit as it is (do not reset it and re-apply patches/)
#   --clean  wipe the build directory first
#
# Inputs (all under streams/gpu-mesa16, git-ignored):
#   downloads/mesa     git clone of mesa-26.2.6 (8e87a503eb), see NOTES.md
#   work/sysroot       glibc/libstdc++ sysroot from streams/asr (make-sysroot.sh)
#                      plus libdrm, zlib headers and libraries pulled from the
#                      device (make-sysroot below)
#   work/venv          Python venv with meson, mako, pyyaml, packaging
#
# Output: work/stage-<variant>/opt/mesa-<variant>, ready to tar to the device.
# No glvnd: libEGL.so.1 and libGLESv2.so.2 are Mesa's own, used through
# LD_LIBRARY_PATH; the system has no Mesa installed and is not touched.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
W=$TOP/work
SRC=$TOP/downloads/mesa
BASE=8e87a503ebd91408c88596d1b9eeb5f4c0b2088d   # mesa-26.2.6
export TMPDIR=$W/tmp
mkdir -p "$TMPDIR"

variant=16bit; clean=0; dev=0
for a in "$@"; do
    case $a in
        --stock) variant=stock ;;
        --host) variant=host ;;
        --dev) dev=1 ;;
        --clean) clean=1 ;;
        *) echo "usage: $0 [--stock|--host] [--dev] [--clean]" >&2; exit 2 ;;
    esac
done
PREFIX=/opt/mesa-$variant
BUILD=$W/build-$variant
STAGE=$W/stage-$variant

# Source tree: stock = BASE, 16bit = BASE + patches (in a worktree of SRC).
if [[ $variant == stock ]]; then
    TREE=$W/src-stock
    [[ -d $TREE ]] || git -C "$SRC" worktree add --detach "$TREE" "$BASE"
else
    TREE=$W/src-16bit
    [[ -d $TREE ]] || git -C "$SRC" worktree add --detach "$TREE" "$BASE"
    if (( ! dev )); then
        git -C "$TREE" checkout -q --detach "$BASE"
        git -C "$TREE" reset -q --hard "$BASE"
        shopt -s nullglob
        for p in "$TOP"/patches/*.patch; do
            git -C "$TREE" -c user.name=build -c user.email=build@localhost am -q --committer-date-is-author-date "$p"
        done
    fi
fi
export PATH=$W/venv/bin:$PATH

if [[ $variant == host ]]; then
    (( clean )) && rm -rf "$BUILD"
    [[ -f $BUILD/build.ninja ]] ||
        meson setup "$BUILD" "$TREE" --prefix="$W/host-install" --libdir=lib \
            -Dbuildtype=debugoptimized \
            -Dplatforms= -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
            -Dglx=disabled -Dglvnd=disabled -Dgbm=disabled \
            -Dgallium-drivers=freedreno -Dvulkan-drivers= -Dfreedreno-kmds=msm \
            -Dllvm=disabled -Dxmlconfig=disabled -Dzstd=disabled -Dlmsensors=disabled \
            -Dvalgrind=disabled -Dlibunwind=disabled -Dgallium-rusticl=false \
            -Dvideo-codecs= -Dteflon=false -Dtools=drm-shim -Dbuild-tests=false
    ninja -C "$BUILD"
    meson install -C "$BUILD" --no-rebuild --quiet
    echo "installed $W/host-install"
    exit 0
fi

SR=$W/sysroot
[[ -f $SR/usr/include/libsync.h ]] || { echo "sysroot missing libdrm; see NOTES.md (Build)" >&2; exit 1; }
CROSS=$W/cross-aarch64.ini
cat > "$CROSS" <<EOF
[binaries]
c = ['clang', '--target=aarch64-linux-gnu', '--sysroot=$SR', '-mcpu=cortex-a53']
cpp = ['clang++', '--target=aarch64-linux-gnu', '--sysroot=$SR', '-mcpu=cortex-a53']
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-Wno-unused-command-line-argument']
cpp_args = ['-Wno-unused-command-line-argument']
c_link_args = ['-fuse-ld=lld', '--rtlib=libgcc', '-L$SR/usr/lib', '-Wl,-rpath-link,$SR/usr/lib']
cpp_link_args = ['-fuse-ld=lld', '--rtlib=libgcc', '-L$SR/usr/lib', '-Wl,-rpath-link,$SR/usr/lib']

[properties]
sys_root = '$SR'
pkg_config_libdir = '$SR/usr/lib/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'cortex-a53'
endian = 'little'
EOF
export PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_LIBDIR=$SR/usr/lib/pkgconfig

(( clean )) && rm -rf "$BUILD"
if [[ ! -f $BUILD/build.ninja ]]; then
    meson setup "$BUILD" "$TREE" --cross-file "$CROSS" \
        --prefix="$PREFIX" --libdir=lib \
        -Dbuildtype=release -Db_ndebug=true \
        -Dplatforms= -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
        -Dglx=disabled -Dglvnd=disabled -Dgbm=disabled \
        -Dgallium-drivers=freedreno -Dvulkan-drivers= -Dfreedreno-kmds=msm \
        -Dllvm=disabled -Dxmlconfig=disabled -Dzstd=disabled -Dlmsensors=disabled \
        -Dvalgrind=disabled -Dlibunwind=disabled -Dgallium-rusticl=false \
        -Dvideo-codecs= -Dteflon=false -Dtools= -Dbuild-tests=false
fi
ninja -C "$BUILD"
rm -rf "$STAGE"
DESTDIR=$STAGE meson install -C "$BUILD" --no-rebuild --quiet
cat > "$STAGE$PREFIX/env.sh" <<ENV
# Source me on the device to use this Mesa ($variant, $(git -C "$TREE" describe --always --tags)).
export LD_LIBRARY_PATH=$PREFIX/lib
export LIBGL_DRIVERS_PATH=$PREFIX/lib/dri
export EGL_DRIVERS_PATH=$PREFIX/lib/dri
export MESA_SHADER_CACHE_DIR=/tmp/mesa-shader-cache-$variant
ENV
git -C "$TREE" log --oneline "$BASE"..HEAD > "$STAGE$PREFIX/PATCHES" || true
du -sh "$STAGE$PREFIX"
echo "staged $STAGE$PREFIX"
