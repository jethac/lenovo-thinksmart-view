#!/usr/bin/env bash
# Build mesa-26.2.6 + patches/0001 (freedreno GMEM fit fix) for the tablet,
# reusing streams/gpu-mesa16's clone, sysroot, venv and cross file, in a tree
# and build directory of its own (gpu-mesa16/work/src-gmem, build-gmem).
# Prefix /opt/mesa-gmem; it is only staged, not installed anywhere.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
G=$(cd "$HERE/../gpu-mesa16" && pwd)
W=$G/work
BASE=8e87a503ebd91408c88596d1b9eeb5f4c0b2088d   # mesa-26.2.6
TREE=$W/src-gmem BUILD=$W/build-gmem STAGE=$W/stage-gmem PREFIX=/opt/mesa-gmem
export TMPDIR=$W/tmp PATH=$W/venv/bin:$PATH
[[ -f $W/cross-aarch64.ini ]] || { echo "run gpu-mesa16/scripts/build-mesa.sh --stock first" >&2; exit 1; }
[[ -d $TREE ]] || git -C "$G/downloads/mesa" worktree add --detach "$TREE" "$BASE"
git -C "$TREE" checkout -q --detach "$BASE"
git -C "$TREE" reset -q --hard "$BASE"
for p in "$HERE"/patches/*.patch; do
    git -C "$TREE" -c user.name=build -c user.email=build@localhost am -q --committer-date-is-author-date "$p"
done
SR=$W/sysroot
export PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_LIBDIR=$SR/usr/lib/pkgconfig
[[ -f $BUILD/build.ninja ]] ||
    meson setup "$BUILD" "$TREE" --cross-file "$W/cross-aarch64.ini" \
        --prefix="$PREFIX" --libdir=lib \
        -Dbuildtype=release -Db_ndebug=true \
        -Dplatforms= -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
        -Dglx=disabled -Dglvnd=disabled -Dgbm=disabled \
        -Dgallium-drivers=freedreno -Dvulkan-drivers= -Dfreedreno-kmds=msm \
        -Dllvm=disabled -Dxmlconfig=disabled -Dzstd=disabled -Dlmsensors=disabled \
        -Dvalgrind=disabled -Dlibunwind=disabled -Dgallium-rusticl=false \
        -Dvideo-codecs= -Dteflon=false -Dtools= -Dbuild-tests=false
ninja -C "$BUILD"
rm -rf "$STAGE"
DESTDIR=$STAGE meson install -C "$BUILD" --no-rebuild --quiet
du -sh "$STAGE$PREFIX"
