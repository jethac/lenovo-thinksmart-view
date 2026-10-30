#!/usr/bin/env bash
# Download and verify the Arch Linux ARM aarch64 generic tarball.
#   fetch-alarm.sh DOWNLOAD_DIR
# Verifies the published .md5 and the detached GPG signature against the
# Arch Linux ARM Build System key 68B3537F39A313B3E574D06777193F152BDBE6A6
# (fetched into a private GNUPGHOME under DOWNLOAD_DIR).
set -euo pipefail
DL=$1
NAME=ArchLinuxARM-aarch64-latest.tar.gz
MIRROR=${ALARM_MIRROR:-http://os.archlinuxarm.org/os}
KEY=68B3537F39A313B3E574D06777193F152BDBE6A6
mkdir -p "$DL"
cd "$DL"
export GNUPGHOME=$PWD/gnupg
mkdir -p -m 0700 "$GNUPGHOME"

verify() {
    md5sum -c --quiet "$NAME.md5" &&
    gpg --batch --status-fd 1 --verify "$NAME.sig" "$NAME" 2>/dev/null |
        grep -q "^\[GNUPG:\] VALIDSIG $KEY "
}

if [[ -f $NAME && -f $NAME.md5 && -f $NAME.sig ]] && gpg --batch --list-keys "$KEY" >/dev/null 2>&1 && verify; then
    echo "fetch-alarm: $NAME already present and verified"
    exit 0
fi
gpg --batch --list-keys "$KEY" >/dev/null 2>&1 ||
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$KEY"
for f in "$NAME.md5" "$NAME.sig" "$NAME"; do
    curl -fL --retry 3 -o "$f.part" "$MIRROR/$f"
    mv "$f.part" "$f"
done
verify || { echo "fetch-alarm: VERIFICATION FAILED" >&2; exit 1; }
echo "fetch-alarm: $NAME verified (md5 + GPG $KEY)"
sha256sum "$NAME"
