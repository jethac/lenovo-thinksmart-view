#!/usr/bin/env bash
# Build a small aarch64 sysroot for fully static C/C++ binaries (glibc,
# libstdc++, libgcc) from the Debian arm64 .debs that rootfs/scripts/fetch-adbd.sh
# already downloaded and verified (Release signature -> Packages index -> SHA-256).
# The SHA-256 of each .deb is checked again here against that MANIFEST.tsv.
#
#   make-sysroot.sh [OUT]      default OUT = streams/asr/work/sysroot
#
# Static linking means the binaries do not depend on the device's glibc or
# gcc-libs version. Nothing runs as root.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
DEBS=$TOP/rootfs/downloads/adbd-debian/debs
OUT=${1:-$HERE/../work/sysroot}
PKGS=(libc6 libc6-dev linux-libc-dev libgcc-s1 libgcc-16-dev libstdc++6 libstdc++-16-dev)

[[ -f $DEBS/MANIFEST.tsv ]] || { echo "run rootfs/scripts/fetch-adbd.sh first" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
for p in "${PKGS[@]}"; do
    read -r _ _ sha file < <(awk -F'\t' -v p="$p" '$1 == p' "$DEBS/MANIFEST.tsv")
    [[ -n ${file:-} ]] || { echo "make-sysroot: $p not in MANIFEST.tsv" >&2; exit 1; }
    [[ $(sha256sum "$DEBS/$file" | cut -d' ' -f1) == "$sha" ]] ||
        { echo "make-sysroot: SHA-256 mismatch for $file" >&2; exit 1; }
    member=$(ar t "$DEBS/$file" | grep '^data\.tar')
    case $member in
        *.xz) ar p "$DEBS/$file" "$member" | tar -xJ -C "$OUT" ;;
        *.zst) ar p "$DEBS/$file" "$member" | zstd -dc | tar -x -C "$OUT" ;;
        *) echo "make-sysroot: unknown member $member" >&2; exit 1 ;;
    esac
done
for d in lib bin sbin; do [[ -e $OUT/$d ]] || ln -s usr/$d "$OUT/$d"; done
find "$OUT" -type l -lname '/*' | while read -r l; do ln -sfn "$OUT$(readlink "$l")" "$l"; done
echo "make-sysroot: $OUT ($(du -sh "$OUT" | cut -f1))"
