#!/usr/bin/env bash
# Cross-compile deqp-gles31 (VK-GL-CTS opengl-es-cts-3.2.9.3, surfaceless EGL
# target) for the tablet against the staged /opt/mesa-16bit headers/libraries.
#
#   build-deqp.sh fetch     clone the CTS and its pinned externals into downloads/
#   build-deqp.sh           configure and build work/build-deqp/modules/gles31/deqp-gles31
#
# The externals are the ones external/fetch_sources.py pins: zlib and libpng
# tarballs (SHA-256 checked against the values in fetch_sources.py), the git
# ones at the pinned commits over ssh. Only deqp-gles31 is built.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
W=$TOP/work
CTS=$TOP/downloads/vk-gl-cts
export TMPDIR=$W/tmp
mkdir -p "$TMPDIR"

if [[ ${1:-} == fetch ]]; then
    [[ -d $CTS ]] || git clone -q --depth 1 --branch opengl-es-cts-3.2.9.3 git@github.com:KhronosGroup/VK-GL-CTS.git "$CTS"
    E=$CTS/external X=$TOP/downloads/cts-ext
    mkdir -p "$X"
    tarball() {  # name url sha256
        local f=$X/$(basename "$2")
        [[ -f $f ]] || curl -sSL -o "$f" "$2"
        echo "$3  $f" | sha256sum -c --quiet
        rm -rf "$E/$1/src"; mkdir -p "$E/$1/src"
        tar xzf "$f" -C "$E/$1/src" --strip-components=1
    }
    tarball zlib https://zlib.net/fossils/zlib-1.2.13.tar.gz b3a24de97a8fdbc835b9833169501030b8977031bcb54b3b3ac13740f846ab30
    tarball libpng https://download.sourceforge.net/libpng/libpng-1.6.27.tar.gz c9d164ec247f426a525a7b89936694aefbc91fb7a50182b198898b8fc91174b4
    cp "$E/libpng/src/scripts/pnglibconf.h.prebuilt" "$E/libpng/src/pnglibconf.h"
    repo() {  # dir url rev
        local d=$E/$1/src
        rm -rf "$d"; mkdir -p "$d"
        git -C "$d" init -q; git -C "$d" remote add origin "$2"
        git -C "$d" fetch -q --depth 1 origin "$3"; git -C "$d" checkout -q FETCH_HEAD
    }
    repo spirv-tools git@github.com:KhronosGroup/SPIRV-Tools.git f98473ceeb1d33700d01e20910433583e5256030
    repo glslang git@github.com:KhronosGroup/glslang.git a0ad0d7067521fff880e36acfb8ce453421c3f25
    repo spirv-headers git@github.com:KhronosGroup/SPIRV-Headers.git 87d5b782bec60822aa878941e6b13c0a9a954c9b
    repo amber git@github.com:google/amber.git 933ecb4d6288675a92eb1650e0f52b1d7afe8273
    repo jsoncpp git@github.com:open-source-parsers/jsoncpp.git 9059f5cad030ba11d37818847443a53918c327b1
    repo ESExtractor git@github.com:Igalia/ESExtractor.git v0.2.5
    exit 0
fi

SR=$W/sysroot
ST=$W/stage-16bit/opt/mesa-16bit
[[ -d $ST ]] || { echo "run build-mesa.sh first" >&2; exit 1; }
# Mesa's headers and libraries inside the sysroot, at their device path.
rm -rf "$SR/opt/mesa-16bit"; mkdir -p "$SR/opt"; cp -a --reflink=auto "$ST" "$SR/opt/"
TC=$W/aarch64-clang.cmake
cat > "$TC" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT $SR)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET aarch64-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET aarch64-linux-gnu)
set(CMAKE_C_FLAGS_INIT "-mcpu=cortex-a53")
# glslang at this revision misses <cstdint> with libstdc++ 16
set(CMAKE_CXX_FLAGS_INIT "-mcpu=cortex-a53 -include cstdint")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld --rtlib=libgcc -L$SR/usr/lib -Wl,-rpath-link,$SR/usr/lib -L$SR/opt/mesa-16bit/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld --rtlib=libgcc -L$SR/usr/lib")
set(CMAKE_FIND_ROOT_PATH $SR/opt/mesa-16bit)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
export PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_LIBDIR=$SR/opt/mesa-16bit/lib/pkgconfig:$SR/usr/lib/pkgconfig
[[ -f $W/build-deqp/build.ninja ]] ||
    cmake -S "$CTS" -B "$W/build-deqp" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TOOLCHAIN_FILE="$TC" -DDE_CPU=DE_CPU_ARM_64 -DDEQP_TARGET=surfaceless \
        -DCMAKE_BUILD_TYPE=Release -DSELECTED_BUILD_TARGETS=deqp-gles31
nice ninja -C "$W/build-deqp" deqp-gles31
ls -la "$W/build-deqp/modules/gles31/deqp-gles31"
