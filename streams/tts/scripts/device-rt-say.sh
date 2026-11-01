#!/bin/bash
# The new synthesisers through straylight-listen's own speech path on the
# tablet (--say-file, pacing sink: nothing is played), as a memory-capped
# transient scope next to the running service, under the device lock.
#
#   device-rt-say.sh push                 voices into the installed share, binary to /var/tmp/rt
#   device-rt-say.sh run TAG LINES [ARGS...]   one --say-file run; results in work/rt/device/TAG/
#   device-rt-say.sh stats                the service's capture/detector stats lines since the last call
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s ${TSV_ADB_SERIAL:-feb0bd1f028e4cb0})
SH=/usr/local/share/straylight-listen
BIN=${BIN:-/home/jethac/Projects/straylight-voice/listen/target/aarch64-unknown-linux-gnu/release/straylight-listen}
SHARE=${SHARE:-$HERE/work/rt/share}
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi
case $1 in
push)
  "${A[@]}" shell "mkdir -p /var/tmp/rt $SH/matcha/ljspeech $SH/piper"
  "${A[@]}" push -q "$BIN" /var/tmp/rt/straylight-listen-new </dev/null
  for f in "$SHARE"/matcha/ljspeech/*; do "${A[@]}" push -q "$(readlink -f "$f")" $SH/matcha/ljspeech/$(basename "$f") </dev/null; done
  for f in "$SHARE"/piper/*; do "${A[@]}" push -q "$f" $SH/piper/ </dev/null; done
  "${A[@]}" push -q /home/jethac/Projects/straylight-voice/listen/tts/lexicon.tsv /var/tmp/rt/lexicon.tsv </dev/null
  "${A[@]}" shell "chmod +x /var/tmp/rt/straylight-listen-new; du -sh $SH/matcha $SH/piper; free -m | sed -n 2p"
  ;;
run)
  tag=$2; lines=$3; shift 3
  "${A[@]}" push -q "$lines" /var/tmp/rt/say.tsv </dev/null
  TSV_DEVICE_LOCK_HELD=1 MEMMAX=${MEMMAX:-700M} "$HERE/scripts/device-rt.sh" run "$tag" ./straylight-listen-new --say-file say.tsv --tts-device pace \
    --tts-lexicon /var/tmp/rt/lexicon.tsv -v "$@"
  ;;
stats)
  "${A[@]}" shell "journalctl -u straylight-listen --no-pager --since '-15 min' | grep -E 'block max|utterance' | grep -o 'straylight-listen: cpu.*\|\"block_max_ms\":[0-9.]*,\"blocks_over_20ms\":[0-9]*,\"xruns\":[0-9]*' | tail -5"
  ;;
esac
