#!/usr/bin/env bash
# Build lk2nd-msm8953 for the Lenovo ThinkSmart View (CD-18781Y) from a clean checkout.
#
# Output: out/lk2nd.img (AVB1-signed with the AOSP verity test key, no QCDT) and
#         out/lk2nd.img.sha256
#
# Requirements (Arch): arm-none-eabi-gcc arm-none-eabi-binutils arm-none-eabi-newlib dtc make
#                      git python3 openssl, plus `uv` (or python -m venv + pip) for the
#                      signing deps, which go into downloads/venv (not system-wide).
# Nothing here touches the tablet.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${LK2ND_REPO:-git@github.com:msm8916-mainline/lk2nd.git}"   # SSH: HTTPS to GitHub hangs here
COMMIT="${LK2ND_COMMIT:-fd380ac637d1af38598e3f3c5321d4c962b96315}"  # main on 2026-10-20
SRC="$HERE/work/lk2nd-$COMMIT"
VENV="$HERE/downloads/venv"
OUT="$HERE/out"
JOBS="${JOBS:-$(nproc)}"

# --- toolchain -------------------------------------------------------------
for t in arm-none-eabi-gcc arm-none-eabi-objcopy dtc make git python3 openssl; do
    command -v "$t" >/dev/null || { echo "missing: $t (sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib dtc)" >&2; exit 1; }
done
echo "toolchain: $(arm-none-eabi-gcc --version | head -1)"

# --- signing deps (bootsignature.py needs pyasn1, pyasn1_modules, pycryptodome) ---
if ! "$VENV/bin/python" -c 'import pyasn1, pyasn1_modules, Crypto' 2>/dev/null; then
    mkdir -p "$HERE/downloads"
    if command -v uv >/dev/null; then
        uv venv -q "$VENV"
        uv pip install -q --python "$VENV/bin/python" \
            'pyasn1==0.6.1' 'pyasn1-modules==0.4.2' 'pycryptodome==3.23.0'
    else
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install -q 'pyasn1==0.6.1' 'pyasn1-modules==0.4.2' 'pycryptodome==3.23.0'
    fi
fi
# lk2nd/scripts/bootsignature.py is run via `#!/usr/bin/env python3`, so the venv goes first.
export PATH="$VENV/bin:$PATH"

# --- clean checkout at the pinned commit -------------------------------------
rm -rf "$SRC"
mkdir -p "$HERE/work"
git clone -q "$REPO" "$SRC"
git -C "$SRC" checkout -q --detach "$COMMIT"
echo "lk2nd: $(git -C "$SRC" log -1 --format='%H %ci %s')"

# --- build ------------------------------------------------------------------
# SIGN_BOOTIMG=1   : append an AVB1 BootSignature (target "/boot"); Lenovo aboot needs one.
# LK2ND_QCDTBS=""  : no QCDT in the boot image header; this aboot refuses images with one
#                    (since lk2nd commit 72e9abac added QCDTBS to msm8953, PR #477).
make -C "$SRC" -j"$JOBS" TOOLCHAIN_PREFIX=arm-none-eabi- \
    SIGN_BOOTIMG=1 LK2ND_QCDTBS="" lk2nd-msm8953

IMG="$SRC/build-lk2nd-msm8953/lk2nd.img"

# --- checks -----------------------------------------------------------------
python3 -I "$HERE/tools/inspect-bootimg.py" "$IMG"
size=$(stat -c %s "$IMG")
limit=$((65536 * 512))   # boot partition: 65536 sectors = 32 MiB
[ "$size" -le "$limit" ] || { echo "image $size > boot partition $limit" >&2; exit 1; }
# The header's 10th word (dt_size in the QCDT mkbootimg) must be 0.
dtsz=$(python3 -I -c 'import struct,sys; print(struct.unpack_from("<I", open(sys.argv[1],"rb").read(), 40)[0])' "$IMG")
[ "$dtsz" -eq 0 ] || { echo "image has a QCDT (dt_size=$dtsz); this aboot will not boot it" >&2; exit 1; }
tail -c 16 "$IMG" | grep -q SEANDROIDENFORCE || { echo "missing SEANDROIDENFORCE trailer" >&2; exit 1; }

mkdir -p "$OUT"
cp "$IMG" "$OUT/lk2nd.img"
( cd "$OUT" && sha256sum lk2nd.img > lk2nd.img.sha256 && cat lk2nd.img.sha256 )
echo "size: $size bytes ($(( (size + 511) / 512 )) of 65536 sectors)"
