#!/usr/bin/env bash
# Cross-build adbd for aarch64 from Debian's android-platform-tools source
# (verified by fetch-adbd.sh) with host clang/lld and a Debian forky arm64
# sysroot made from the verified .debs. Runs as the invoking user, no
# namespace, nothing installed on the host.
#
#   build-adbd.sh DOWNLOAD_DIR WORK_DIR
#
# Result: WORK_DIR/stage/opt/adbd/{bin/adbd,lib/*.so*,libexec/adbd-reboot},
# ready to be copied into the root filesystem. Uses Debian's own makefiles
# (debian/system/{libcrypto_utils,libadb,adbd}.mk) and Debian's patch series,
# except adbd-don-t-require-authorization-on-Linux.patch, plus the patches in
# scripts/adbd/patches/.
set -euo pipefail
DL=$1 W=$2
HERE=$(cd "$(dirname "$0")" && pwd)
VER=34.0.5
DEBREV=13
TSVREV=tsv1
TRIPLE=aarch64-linux-gnu
SKIP_PATCH=adbd/adbd-don-t-require-authorization-on-Linux.patch

for t in clang clang++ ld.lld patchelf ar xz zstd patch make qemu-aarch64-static llvm-readelf; do
    command -v $t >/dev/null || { echo "build-adbd: missing tool $t" >&2; exit 1; }
done

rm -rf "$W"
mkdir -p "$W"
SRC=$W/src SYS=$W/sysroot STAGE=$W/stage
mkdir -p "$SRC" "$SYS" "$STAGE"

# ---------------------------------------------------------------- sysroot
# Extract data.tar.* of every verified .deb (no maintainer scripts run).
while IFS=$'\t' read -r name _ _ file; do
    deb=$DL/debs/$file
    member=$(ar t "$deb" | grep '^data\.tar')
    case $member in
        *.xz) ar p "$deb" "$member" | tar -xJ -C "$SYS" ;;
        *.zst) ar p "$deb" "$member" | zstd -dc | tar -x -C "$SYS" ;;
        *.gz) ar p "$deb" "$member" | tar -xz -C "$SYS" ;;
        *) echo "build-adbd: $name: unknown member $member" >&2; exit 1 ;;
    esac
done < "$DL/debs/MANIFEST.tsv"
# merged-/usr symlinks (normally created by base-files/usrmerge)
for d in lib bin sbin; do [[ -e $SYS/$d ]] || ln -s usr/$d "$SYS/$d"; done
# Absolute symlinks inside the sysroot would point at the host.
find "$SYS" -type l -lname '/*' | while read -r l; do
    ln -sfn "$SYS$(readlink "$l")" "$l"
done

# ---------------------------------------------------------------- source + patches
tar -xJf "$DL/src/android-platform-tools_$VER.orig.tar.xz" -C "$SRC"
tar -xJf "$DL/src/android-platform-tools_$VER-$DEBREV.debian.tar.xz" -C "$SRC"
grep -qx "$SKIP_PATCH" "$SRC/debian/patches/series" ||
    { echo "build-adbd: $SKIP_PATCH not in series any more; recheck the auth path" >&2; exit 1; }
while read -r p; do
    [[ -z $p || $p == \#* || $p == "$SKIP_PATCH" ]] && continue
    patch -d "$SRC" -p1 -s -F0 --no-backup-if-mismatch < "$SRC/debian/patches/$p"
done < "$SRC/debian/patches/series"
for p in "$HERE"/adbd/patches/*.patch; do
    patch -d "$SRC" -p1 -s -F0 --no-backup-if-mismatch < "$p"
done
# The auth bypass must be gone: auth_required stays at its default (true).
! grep -q '^    auth_required = false;$' "$SRC/packages/modules/adb/daemon/main.cpp" ||
    { echo "build-adbd: unconditional auth bypass still present" >&2; exit 1; }
grep -q '^bool auth_required = true;' "$SRC/packages/modules/adb/daemon/auth.cpp"

# ---------------------------------------------------------------- protobuf sources
# Debian regenerates the .pb.cc files with protoc in override_dh_auto_configure;
# use the sysroot's arm64 protoc 3.21.12 (matches libprotobuf-dev) under qemu.
PROTOC=(qemu-aarch64-static -L "$SYS" "$SYS/usr/bin/protoc")
"${PROTOC[@]}" --version
(cd "$SRC/packages/modules/adb/proto" &&
    for p in *.proto; do "${PROTOC[@]}" --cpp_out=. "$p"; done)

# ---------------------------------------------------------------- compile
# Debian's flags (debian/rules + dpkg-buildflags hardening=+all), cross.
export DEB_HOST_MULTIARCH=$TRIPLE
export DEB_VERSION=$VER-$DEBREV+$TSVREV
export PLATFORM_TOOLS_VERSION=$VER
export CC="clang --target=$TRIPLE --sysroot=$SYS"
export CXX="clang++ --target=$TRIPLE --sysroot=$SYS"
HARDEN="-O2 -fstack-protector-strong -fstack-clash-protection -mbranch-protection=standard -fPIC -gdwarf-4"
export CFLAGS="$HARDEN -std=gnu17"
export CXXFLAGS="$HARDEN -std=gnu++2a"
export CPPFLAGS="-D_FORTIFY_SOURCE=2 -DNDEBUG -UDEBUG -fmessage-length=0 -fno-exceptions \
-fno-strict-aliasing -no-canonical-prefixes -Wno-c99-designator -Wno-gnu-designator \
-Wno-gnu-folding-constant -isystem $SYS/usr/include/android"
export LDFLAGS="-fuse-ld=lld -Wl,--build-id=sha1 -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -fPIC \
-L$SYS/usr/lib/$TRIPLE/android -L$SYS/usr/lib/$TRIPLE"
mkdir -p "$SRC/debian/out/system"
J=$(nproc)
for mk in libcrypto_utils libadb adbd; do
    make -C "$SRC" -j"$J" -s --file="debian/system/$mk.mk"
done
llvm-strip --strip-unneeded -o "$W/adbd" "$SRC/debian/out/system/adbd" 2>/dev/null ||
    cp "$SRC/debian/out/system/adbd" "$W/adbd"

# ---------------------------------------------------------------- stage
# Private libraries: only what Arch Linux ARM does not provide with the same
# soname. libc, libstdc++, libgcc_s, brotli, lz4, zstd, libsystemd, zlib and
# libbsd come from Arch at run time.
PRIV=(android/libbase.so.0 android/libcutils.so.0 android/liblog.so.0
      android/libcrypto.so.0 android/libssl.so.0 libprotobuf.so.32)
O=$STAGE/opt/adbd
install -d -m 0755 "$O/bin" "$O/lib" "$O/libexec"
install -m 0755 "$W/adbd" "$O/bin/adbd"
patchelf --set-rpath /opt/adbd/lib "$O/bin/adbd"
for l in "${PRIV[@]}"; do
    real=$(readlink -f "$SYS/usr/lib/$TRIPLE/$l")
    install -m 0644 "$real" "$O/lib/$(basename "$l")"
    # shellcheck disable=SC2016  # literal $ORIGIN for the dynamic loader
    patchelf --set-rpath '$ORIGIN' "$O/lib/$(basename "$l")"
done
install -m 0755 "$HERE/adbd/adbd-reboot" "$O/libexec/adbd-reboot"
cp "$SRC/packages/modules/adb/NOTICE" "$O/NOTICE"
{
    echo "adbd $VER-$DEBREV+$TSVREV, built $(date -u +%Y-%m-%dT%H:%MZ) by rootfs/scripts/build-adbd.sh"
    echo "source: Debian android-platform-tools $VER-$DEBREV (forky), Debian patches except $SKIP_PATCH,"
    echo "        plus: $(cd "$HERE/adbd/patches" && echo *.patch)"
    echo "private libraries (Debian forky arm64):"
    awk -F'\t' '$1 ~ /^(android-libbase|android-libcutils|android-liblog|android-libboringssl|libprotobuf32t64)$/' \
        "$DL/debs/MANIFEST.tsv" | awk -F'\t' '{print "  " $1 " " $2 " sha256:" $3}'
    echo "sha256:"
    (cd "$O" && sha256sum bin/adbd lib/* | sed 's/^/  /')
} > "$O/BUILDINFO"

# Every NEEDED entry must resolve to /opt/adbd/lib or to a library that the
# Arch image provides (checked again inside the rootfs by build-rootfs.sh).
echo "build-adbd: NEEDED by adbd: $(llvm-readelf -d "$O/bin/adbd" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
cat "$O/BUILDINFO"
