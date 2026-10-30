#!/usr/bin/env bash
# Download and verify everything needed to build adbd for the image:
# the Debian android-platform-tools source and the arm64 .debs that make up
# the cross sysroot (and the few runtime libraries shipped in /opt/adbd/lib).
#
#   fetch-adbd.sh DOWNLOAD_DIR          (normally rootfs/downloads/adbd-debian)
#
# Chain of trust, all checked on every run (offline once downloaded):
#   Debian archive keys (fingerprints pinned below)
#     -> InRelease of forky at snapshot $SNAPSHOT (gpgv, VALIDSIG on a pinned key)
#     -> SHA256 of main/binary-arm64/Packages.xz and main/source/Sources.xz
#     -> SHA256 of every .deb and source file listed in those indices
# Each package's SHA256 is also pinned below, so a different archive state
# cannot silently change what is built.
set -euo pipefail
DL=$1
HERE=$(cd "$(dirname "$0")" && pwd)
IDX="python3 -I $HERE/debian-index.py"
SNAPSHOT=20261030T000000Z
SUITE=forky
SNAP=https://snapshot.debian.org/archive/debian/$SNAPSHOT
MIRROR=https://deb.debian.org/debian
# Debian Archive Automatic Signing Keys 12/bookworm and 13/trixie (primary
# fingerprints; checked against both ftp-master.debian.org/keys and
# keyserver.ubuntu.com when first pinned).
KEYS=(B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8 04B54C3CDCA79751B16BC6B5225629DF75B188BD)
KEYFILES=(archive-key-12.asc archive-key-13.asc)

SRC_PKG=android-platform-tools
SRC_VER=34.0.5-13
# name sha256 (versions come from the verified Packages index)
DEBS=(
    # shipped privately in /opt/adbd/lib on the device
    "android-libbase eda3383b0948e9d83c05de2580b9e7abc91043f5a5eda720ac78613de91eff69"
    "android-libcutils bc080151a31ae569634e64101fe8769c4e142a12dbdcc28f41e7c437fb2b6c36"
    "android-liblog 891458f051560a51d2e3b0458b8437529d05b4f216ed4350b821dbbfcb86e4b1"
    "android-libboringssl d91e99628c49781f53277a5ba06ae3e6f7b1d5b1bb46661762bb7fd3ee7edf64"
    "libprotobuf32t64 12cf22c111f13078a460f4824905df6727834b4631d87bb23e8f929a28040020"
    # build sysroot only
    "libc6 2315e75157bf67622bb435724de8be3c4c6f5bb33f3f26e8310842ea66093c74"
    "libc6-dev 2fe4fa9f4d59caf63afd5098ce143a63ed8933cec60c5b4cb4485aebbdfa6dce"
    "linux-libc-dev 7eaa4fabe0503c808f4b6bf3dd240de1345f9855c97ea8099c4606409221aa1e"
    "libgcc-s1 0b64848c56954c919709a045dc77972d5787922e3585795bfe2fcb1009647bad"
    "libgcc-16-dev 209b8fb41f83790a585fe0ef8e7b35314b1c49569cccb852d3a443cf163da797"
    "libstdc++6 33c35ea990a913d6e7013d6845b7f4aaed65b70ee01ceb7da86aa25129f866c6"
    "libstdc++-16-dev f83beb28da7dc3004c5f372524a8f0a5dfcd89a4a1f913bc6f73e365a7a66902"
    "android-libbase-dev 55c7e781e79b1dd85de7ddbf717647b9df1cfec0d33f15c7c4e6598297511854"
    "android-libcutils-dev de4eed9dfa7effeb297d06a6285458a8a575f0572c5b42832d58eb49b89049e3"
    "android-liblog-dev 19b790584cddc26a6ca6d1265052f54f96e0f73df762b8f02458cb180e1fbdaa"
    "android-libboringssl-dev 0963a94b4bb35f018cc9b8bd55164cc4820b82fe355c9fb0af14ae011729241d"
    "libprotobuf-dev 0e92e8c55e690efe03870fe10ee2884a070143cefbc6c2e0610d0f14fb98cd00"
    "libprotobuf-lite32t64 802c377dfe2a4535268e5e665d4e60cc2eb322d4e9686a91ce21f95c75bd0adf"
    "libprotoc32t64 45eaf62eccaacaa2cbc0333762005e1b17308650d223d64b6a27cf99bd8f15b6"
    "protobuf-compiler 320c435617fcbcb722904c8f22da6c22ddac293992964e41775647224ba4ee3d"
    "libbrotli1 8708a1385c7d8c29432010e8b1f30d83a6b908989b50b56dc2c7316bfa9fabbf"
    "libbrotli-dev ae7b0dc211388ffd3f14ecc8b6c3c21093302b2e485108571df7e525ee5f84ea"
    "liblz4-1 c088f662f310c47a92b9120f6a6e7b430ce3f0a029d3d1a554a0d3acf753b8b7"
    "liblz4-dev 0d1a832090762511a2cf9e110a9bb6fb91bda4ecd917cf08563e144a8f4d443e"
    "libzstd1 e99e6e244d6c80f1c8e96cb68bb04bffc6848b12e3dcc5a35f6a775e4332e936"
    "libzstd-dev 7e16181a7773292e3489704f7c4ff42e373228fe1237ec33e5b58814f8a8a0a1"
    "libsystemd0 558f41b5b1f56d51e74d94ce4bd1d719875983613f809c49c83900c2bbd87149"
    "libsystemd-dev 0a9402da80b8880db6f7e18babf3b2bd91a741abf2d1082e679a056657d86c6e"
    "zlib1g a77a1a137da4f6e440fa638b00a60dc3d7124e9678402ea5335bc02e75bf267e"
    "zlib1g-dev e7d9da2391c011b34357b2cefcc889e6d34e790da896934a97dd52db787b742f"
    "libbsd0 2e4ebe1b975367700ae4a45970e67a6c477043b891827f09c941ea5859f6a8ca"
    "libmd0 7237eae7065e13453f7766f5bccb72cf7d062f87c59c783dfca391f5936f347e"
    "libcap-dev fe2e50fe61c36a2f09ad77a7fa6b25df847227f3c699f8f3381f30653cbbd59d"
)
SRC_FILES=(
    "06acaffb158b4045325222183ffe09ede5b8f6f6f38a8d873f44b4486e57d776 android-platform-tools_34.0.5-13.dsc"
    "4893f6a85b205f1df2c35cde5d6ca3bedd5e9f19afdb3b5ac781e647aa2243f4 android-platform-tools_34.0.5.orig.tar.xz"
    "5886a4353775bdb373af5edcf56ada70b88e19b3312f7d64905210c855a972bf android-platform-tools_34.0.5-13.debian.tar.xz"
)

mkdir -p "$DL"/{keys,dists,debs,src}
cd "$DL"

fetch() { # url... -> $out (first that works)
    local out=$1; shift
    [[ -s $out ]] && return 0
    local u
    for u in "$@"; do
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$out.part" "$u"; then
            mv "$out.part" "$out"
            return 0
        fi
    done
    rm -f "$out.part"
    echo "fetch-adbd: could not download $out" >&2
    return 1
}
check_sha() { # sha file
    [[ $(sha256sum "$2" | cut -d' ' -f1) == "$1" ]] || {
        echo "fetch-adbd: SHA256 MISMATCH for $2" >&2
        rm -f "$2"
        return 1
    }
}

# ---- keys
for i in "${!KEYS[@]}"; do
    f=keys/${KEYFILES[$i]}
    fetch "$f" "https://ftp-master.debian.org/keys/${KEYFILES[$i]}"
    fpr=$(gpg --batch --show-keys --with-colons "$f" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    [[ $fpr == "${KEYS[$i]}" ]] || { echo "fetch-adbd: $f has fingerprint $fpr, expected ${KEYS[$i]}" >&2; exit 1; }
done
cat "${KEYFILES[@]/#/keys/}" | gpg --batch --dearmor > keys/debian-archive.gpg.tmp
mv keys/debian-archive.gpg.tmp keys/debian-archive.gpg

# ---- InRelease
D=dists/$SUITE
mkdir -p "$D"
fetch "$D/InRelease" "$SNAP/dists/$SUITE/InRelease"
status=$(gpgv --keyring keys/debian-archive.gpg --status-fd 1 --output "$D/Release.verified" \
    "$D/InRelease" 2>/dev/null) || { echo "fetch-adbd: InRelease signature check failed" >&2; exit 1; }
ok=0
for k in "${KEYS[@]}"; do
    grep -Eq "^\[GNUPG:\] VALIDSIG .* $k\$" <<<"$status" && ok=1
done
[[ $ok == 1 ]] || { echo "fetch-adbd: InRelease not signed by a pinned Debian archive key" >&2; exit 1; }
grep -q "^Codename: $SUITE\$" "$D/Release.verified"

for idx in main/binary-arm64/Packages.xz main/source/Sources.xz; do
    mkdir -p "$D/$(dirname "$idx")"
    read -r sha _ < <($IDX release-sha256 "$D/Release.verified" "$idx")
    fetch "$D/$idx" "$SNAP/dists/$SUITE/$idx"
    check_sha "$sha" "$D/$idx"
    xz -dc "$D/$idx" > "$D/${idx%.xz}"
done
PKGS=$D/main/binary-arm64/Packages
SRCS=$D/main/source/Sources

# ---- source package
{ read -r ver dir; mapfile -t lines; } < <($IDX source "$SRCS" "$SRC_PKG")
[[ $ver == "$SRC_VER" ]] || { echo "fetch-adbd: $SRC_PKG is $ver in the index, expected $SRC_VER" >&2; exit 1; }
for want in "${SRC_FILES[@]}"; do
    read -r sha name <<<"$want"
    printf '%s\n' "${lines[@]}" | grep -q "^$sha [0-9]* $name\$" ||
        { echo "fetch-adbd: $name/$sha not in the signed Sources index" >&2; exit 1; }
    fetch "src/$name" "$SNAP/$dir/$name" "$MIRROR/$dir/$name"
    check_sha "$sha" "src/$name"
done

# ---- binary packages
: > debs/MANIFEST.tmp
for want in "${DEBS[@]}"; do
    read -r name sha <<<"$want"
    read -r ver file isha _ < <($IDX package "$PKGS" "$name")
    [[ $isha == "$sha" ]] ||
        { echo "fetch-adbd: $name: pinned $sha, signed index has $isha ($ver)" >&2; exit 1; }
    out=debs/$(basename "$file")
    fetch "$out" "$SNAP/$file" "$MIRROR/$file"
    check_sha "$sha" "$out"
    printf '%s\t%s\t%s\t%s\n' "$name" "$ver" "$sha" "$(basename "$file")" >> debs/MANIFEST.tmp
done
mv debs/MANIFEST.tmp debs/MANIFEST.tsv
echo "fetch-adbd: $SRC_PKG $SRC_VER source and ${#DEBS[@]} arm64 packages verified (Debian $SUITE @ $SNAPSHOT)"
