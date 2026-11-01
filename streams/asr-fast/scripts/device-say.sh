#!/bin/bash
# Synthesise test sentences with the tablet's own speech output (the installed
# straylight-listen, --say-file, nothing played) for the term checks
# ("Straylight", "ai&", names), as a transient unit next to the running
# service. Under the device lock.
#
#   device-say.sh LINES.tsv OUTDIR
#
# LINES: id<TAB>lang<TAB>text. OUTDIR gets the WAVs, resampled to 16 kHz mono
# for sla-bench (scripts/resample16k.py).
set -euo pipefail
LINES=$1 OUT=$2
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
D=/var/tmp/asrfast/say
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 1800 "$PROJ/.device.lock" "$0" "$@"
fi
"${A[@]}" shell "rm -rf $D; mkdir -p $D/out"
"${A[@]}" push -q "$LINES" $D/lines.tsv
"${A[@]}" shell "cd $D && systemd-run --quiet --wait --pipe --unit=asr-say -p Nice=5 -p MemoryMax=600M -p MemorySwapMax=0 \
    /usr/local/bin/straylight-listen --no-ui --no-asr --say-file $D/lines.tsv --say-cps 0 --tts-device pace --say-out $D/out > $D/log 2>&1; echo rc \$?; ls $D/out"
mkdir -p "$OUT/raw"
"${A[@]}" pull -q $D/out/. "$OUT/raw/"
"${A[@]}" pull -q $D/log "$OUT/say.log"
"${A[@]}" shell "rm -rf $D"
uv run --script "$HERE/scripts/resample16k.py" "$OUT" "$OUT"/raw/*.wav
ls "$OUT"
