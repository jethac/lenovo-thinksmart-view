#!/bin/bash
# Time the NanoCodec decoder alone on the tablet (tools/nanocodec, offline decode of
# a fixed code file, streamed in 4-frame chunks as during synthesis), under the device lock, for several weight paths and thread
# counts. Files go to /dev/shm/tts-codec and are removed afterwards.
#
#   device-codec.sh CODES OUTDIR
set -euo pipefail
CODES=$(realpath "$1"); OUT=$(realpath -m "$2"); mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
M=$HERE/downloads/models
D=/dev/shm/tts-codec
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi
"${A[@]}" shell "mkdir -p $D"
"${A[@]}" push -q "$HERE/work/build-a53/bin/nanocodec" "$M/nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf" \
  "$M/nanocodec.decoder.f32.local.gguf" "$CODES" $D/
trap '"${A[@]}" shell "rm -rf $D" || true' EXIT
C=$(basename "$CODES")
for t in 8 4; do  # threads
  for v in "f16 0 nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf" "f16-q8 1 nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf" "f32 0 nanocodec.decoder.f32.local.gguf"; do
    set -- $v
    "${A[@]}" shell "cd $D && chmod +x nanocodec && NANOCODEC_CPU_Q8=$2 systemd-run --scope -q -p MemoryMax=900M -p MemorySwapMax=0 ./nanocodec -m $3 --codes $C -o $1-t$t.wav -t $t --cpu --stream --chunk-frames 4 2>&1 | grep decode" </dev/null | sed "s/^/$1 t=$t: /" | tee -a "$OUT/codec.txt"
    "${A[@]}" pull -q $D/$1-t$t.wav "$OUT/" </dev/null
  done
done
