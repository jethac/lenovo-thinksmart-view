#!/bin/bash
# Speed of untrained exports (speed does not depend on the weights) with
# straylight-listen --tts-bench on the tablet, one model at a time in
# /dev/shm, in a capped scope next to the running service, under the lock.
#   device-speed.sh BENCH.tsv THREADS MODEL_DIR...   (each with model.onnx, voice.bin)
set -euo pipefail
PROJ=$(cd "$(dirname "$0")/../../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
D=/dev/shm/distil
bench=$1 thr=$2; shift 2
exec 9>"$PROJ/.device.lock"; flock -w 1800 9
"${A[@]}" push -q "$bench" $D/bench.tsv </dev/null
for m in "$@"; do
  "${A[@]}" shell "rm -rf $D/speed && mkdir -p $D/speed" </dev/null
  "${A[@]}" push -q "$m/model.onnx" "$m/voice.bin" $D/speed/ </dev/null
  echo "== $(basename "$m") ($thr threads)"
  "${A[@]}" shell "cd $D && systemd-run --scope -q -p MemoryMax=700M -p MemorySwapMax=0 nice -n 5 ./straylight-listen --tts-bench bench.tsv --tts-model speed/model.onnx --tts-voice speed/voice.bin --tts-threads $thr --repeat 2 2>/dev/null | grep '\"rep\":1'" </dev/null
done
"${A[@]}" shell "rm -rf $D/speed" </dev/null
