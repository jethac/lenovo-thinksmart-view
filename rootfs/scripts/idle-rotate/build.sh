#!/usr/bin/env bash
# Cross-compile tsv-idle-rotate for aarch64 with host clang + ld.lld against an
# Arch Linux ARM sysroot (glibc, libm, libdrm and their headers). Runs as any
# user; nothing needs root.
#
#   build.sh --sysroot DIR OUTDIR    DIR is an Arch Linux ARM root (build-rootfs.sh
#                                    passes the image tree it is building)
#   build.sh [--image IMG] OUTDIR    take the sysroot from a built image
#                                    (default rootfs/out/thinksmart-alarm-system.img,
#                                    root = MBR p2 at sector 264192), extracted
#                                    rootless with debugfs into $TSV_WORK/idle-rotate-sysroot
#
# Output: OUTDIR/tsv-idle-rotate (PIE, dynamically linked: libdrm.so.2, libm.so.6, libc.so.6).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
SYS="" IMG=$TOP/out/thinksmart-alarm-system.img
while [[ $# -gt 1 ]]; do
    case $1 in
        --sysroot) SYS=$2; shift 2 ;;
        --image) IMG=$2; shift 2 ;;
        *) break ;;
    esac
done
[[ $# == 1 ]] || { echo "usage: $0 [--sysroot DIR | --image IMG] OUTDIR" >&2; exit 2; }
OUT=$1
for t in clang ld.lld zstd; do
    command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

if [[ -z $SYS ]]; then
    command -v debugfs >/dev/null || { echo "missing tool: debugfs (e2fsprogs)" >&2; exit 1; }
    SYS=${TSV_WORK:-$TOP/work}/idle-rotate-sysroot
    stamp="$(stat -c '%s %Y' "$IMG")"
    if [[ ! -f $SYS/.stamp || $(cat "$SYS/.stamp") != "$stamp" ]]; then
        echo "idle-rotate: extracting sysroot from $IMG"
        rm -rf "$SYS"; mkdir -p "$SYS/usr/lib"
        dev="$IMG?offset=$((264192 * 512))"
        debugfs -R "rdump /usr/include $SYS/usr" "$dev" 2>/dev/null
        # Follow symlinks inside the image (debugfs would copy the link itself).
        resolve() { # path -> path of the regular file it ends at
            local p=$1 t i
            for i in 1 2 3 4 5 6 7 8; do
                t=$(debugfs -R "stat $p" "$dev" 2>/dev/null | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p')
                [[ -z $t ]] && { echo "$p"; return; }
                [[ $t == /* ]] && p=$t || p=$(dirname "$p")/$t
            done
            echo "$p"
        }
        for f in Scrt1.o crti.o crtn.o libc.so libc.so.6 libc_nonshared.a libm.so libm.so.6 \
            libmvec.so libmvec.so.1 ld-linux-aarch64.so.1 libdrm.so; do
            debugfs -R "dump $(resolve /usr/lib/$f) $SYS/usr/lib/$f" "$dev" 2>/dev/null || true
            [[ -s $SYS/usr/lib/$f ]] || rm -f "$SYS/usr/lib/$f"
        done
        for f in Scrt1.o crti.o crtn.o libc.so libc.so.6 libc_nonshared.a libm.so libdrm.so; do
            [[ -s $SYS/usr/lib/$f ]] || { echo "sysroot lacks usr/lib/$f" >&2; exit 1; }
        done
        echo "$stamp" > "$SYS/.stamp"
    fi
fi
for f in usr/include/stdio.h usr/include/xf86drm.h usr/include/xf86drmMode.h usr/include/libdrm/drm_fourcc.h \
    usr/lib/Scrt1.o usr/lib/libdrm.so; do
    [[ -e $SYS/$f ]] || { echo "sysroot $SYS lacks $f" >&2; exit 1; }
done

mkdir -p "$OUT"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
zstd -dqf "$HERE/logo-524x175.bgrx.zst" -o "$tmp/logo.bgrx"
[[ $(stat -c %s "$tmp/logo.bgrx") == $((524 * 175 * 4)) ]] || { echo "bad logo asset" >&2; exit 1; }

L=$SYS/usr/lib
# No gcc in the sysroot, so no crtbegin/crtend or libgcc: link by hand with
# glibc's own start files (plain C needs nothing from libgcc on aarch64).
clang --target=aarch64-linux-gnu --sysroot="$SYS" -mcpu=cortex-a53 \
    -std=gnu11 -O2 -g0 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-plt \
    -I"$SYS/usr/include/libdrm" -DLOGO_FILE="\"$tmp/logo.bgrx\"" \
    -c "$HERE/tsv-idle-rotate.c" -o "$tmp/tsv-idle-rotate.o"
ld.lld --sysroot="$SYS" -pie -z relro -z now -z noexecstack --as-needed --build-id=sha1 -s \
    --hash-style=gnu --dynamic-linker=/lib/ld-linux-aarch64.so.1 -L"$L" \
    -o "$tmp/tsv-idle-rotate" \
    "$L/Scrt1.o" "$L/crti.o" "$tmp/tsv-idle-rotate.o" -ldrm -lm -lc "$L/crtn.o"
install -m 0755 "$tmp/tsv-idle-rotate" "$OUT/tsv-idle-rotate"
echo "idle-rotate: built $OUT/tsv-idle-rotate ($(stat -c %s "$OUT/tsv-idle-rotate") bytes)"
