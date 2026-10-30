#!/usr/bin/env bash
# Build the TAS5782M speaker tuning (DSP configuration) firmware from Lenovo's
# GPL kernel source for the CD-18781Y.
#
#   fetch-tas5782m-tuning.sh DOWNLOAD_DIR FIRMWARE_DIR MANIFEST_TSV
#
# Lenovo ships the speaker EQ and excursion protection as a register table in
# sound/soc/codecs/tas5782m.h of its GPL release; the mainline tas5782m driver
# loads it as tas5782m_dsp_lenovo_cd-18781y.bin (tas5782m-dsp-fw.py). Lenovo
# publishes no checksum; the tarball is pinned by size (the server's
# Content-Length) and by the sha256 of the copy the speaker stream tested, and
# tas5782m-dsp-fw.py checks the header's own hash again.
set -euo pipefail
DL=$1 FW=$2 MANIFEST=$3
HERE=$(cd "$(dirname "$0")" && pwd)
URL=https://download.lenovo.com/consumer/mobiles/lenovo_cd-18781y_cd-18781y.201218.2018_opensource.tgz
TGZ=$DL/lenovo_cd-18781y_cd-18781y.201218.2018_opensource.tgz
SIZE=376626146
SHA=713685c2aaacff8c3e6f7a5d8e31c7fad48da1f73f9f6a563c14e7386469a384
MEMBER=Lenovo_CD-18781Y_CD-18781Y.201218.2018_opensource/kernel/msm-3.18/sound/soc/codecs/tas5782m.h
OUT=tas5782m_dsp_lenovo_cd-18781y.bin

mkdir -p "$DL" "$FW"
ok() { [[ -f $TGZ && $(stat -L -c %s "$TGZ") == "$SIZE" ]] && echo "$SHA  $TGZ" | sha256sum -c --quiet; }
if ! ok; then
    curl -fL --retry 3 -o "$TGZ.part" "$URL"
    mv "$TGZ.part" "$TGZ"
    ok || { echo "fetch-tas5782m-tuning: $TGZ VERIFICATION FAILED" >&2; exit 1; }
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
tar -xzf "$TGZ" -C "$TMP" "$MEMBER"
python3 -I "$HERE/tas5782m-dsp-fw.py" "$TMP/$MEMBER" "$FW/$OUT"
chmod 0644 "$FW/$OUT"
printf '/lib/firmware/%s\t%s\t%s\t%s\t%s\n' "$OUT" "Lenovo GPL source" \
    "$(basename "$TGZ"):$MEMBER (converted)" \
    "$(sha256sum "$FW/$OUT" | cut -d' ' -f1)" "$(stat -c %s "$FW/$OUT")" >> "$MANIFEST"
