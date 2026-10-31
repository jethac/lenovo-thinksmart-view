#!/usr/bin/env bash
# One request through the air: a "Hey Straylight, ..." clip (48 kHz, voice-
# pipeline work/testset/48k) played through the tablet's speaker to the
# installed service, which then answers aloud with Kokoro. The amp is held at
# AMP (default 187 = -10 dB) for the test and put back afterwards. Under the
# device lock.
#
#   device-kokoro-acoustic.sh TAG CLIP.wav
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
TAG=$1; CLIP=$2
ADB="adb -s ${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"
LOG=$HERE/work/kokoro/device/acoustic-$TAG.log
mkdir -p "$(dirname "$LOG")"
exec 9> "$PROJ/.device.lock"
flock -w 3600 9
$ADB push -q "$CLIP" /var/tmp/kokoro-clip.wav </dev/null
$ADB shell "set -u
AMP='Speaker Amp Digital Playback Volume'
old=\$(amixer -c0 cget name=\"\$AMP\" | sed -n 's/.*: values=\([0-9]*\).*/\1/p')
trap 'amixer -q -c0 cset name=\"\$AMP\" \$old; rm -f /var/tmp/kokoro-clip.wav' EXIT
amixer -q -c0 cset name=\"\$AMP\" ${AMP:-187}
c=\$(journalctl -u straylight-listen -n 0 --show-cursor -q | sed -n 's/^-- cursor: //p')
aplay -q -D hw:0,0 /var/tmp/kokoro-clip.wav
for i in \$(seq 1 240); do
    journalctl -u straylight-listen --after-cursor=\"\$c\" -o cat -q | grep -q '\"outcome\"' && break
    sleep 0.5
done
journalctl -u straylight-listen --after-cursor=\"\$c\" -o cat -q
echo \"# amp back to \$old\"" </dev/null > "$LOG" 2>&1
grep -E 'wake at|request|tts:|"outcome"' "$LOG" | cut -c1-300
