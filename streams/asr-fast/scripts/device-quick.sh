#!/bin/bash
# First speed look at a sherpa-onnx model on the tablet: the prebuilt
# sherpa-onnx-offline / sherpa-onnx binary (v2.0.1) over the command clips of
# one language, as a transient unit next to the running straylight-listen
# (memory cap, no swap, nice 5), model and audio on the eMMC under
# /var/tmp/asrfast (not /dev/shm, which would be RAM). Under the device lock.
#
#   device-quick.sh TAG MODEL_DIR THREADS LANGS -- SHERPA_ARGS...
#
# SHERPA_ARGS name the model files relative to MODEL_DIR as @/FILE, e.g.
#   -- --sense-voice-model=@/model.int8.onnx --tokens=@/tokens.txt
# BIN=sherpa-onnx for streaming models (default sherpa-onnx-offline).
# Output: work/results/quick/TAG-LANG.log (the binary's output, /usr/bin/time).
set -euo pipefail
TAG=$1 MD=$2 TH=$3 LANGS=$4; shift 4; [[ ${1:-} == -- ]] && shift
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
SH=$PROJ/streams/asr/downloads/sherpa/sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu
TS=$PROJ/streams/asr/work/testset
BIN=${BIN:-sherpa-onnx-offline}
MEM=${MEM:-450M}
SSH=(ssh -o ConnectTimeout=10 jethac@172.16.42.1)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
D=/var/tmp/asrfast
OUT=$HERE/work/results/quick; mkdir -p "$OUT"
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 1800 "$PROJ/.device.lock" "$0" "$TAG" "$MD" "$TH" "$LANGS" -- "$@"
fi
m=$(basename "$MD")
"${A[@]}" shell "mkdir -p $D/bin $D/lib $D/models $D/wav"
"${A[@]}" shell "test -f $D/lib/libonnxruntime.so" || "${A[@]}" push -q "$SH"/lib/*.so $D/lib/
"${A[@]}" shell "test -x $D/bin/$BIN" || { "${A[@]}" push -q "$SH/bin/$BIN" $D/bin/; "${A[@]}" shell "chmod 755 $D/bin/$BIN"; }
"${A[@]}" shell "test -d $D/models/$m" || "${A[@]}" push -q "$MD" $D/models/
ARGS=()
for x in "$@"; do ARGS+=("${x//@\//$D/models/$m/}"); done
for L in $LANGS; do
  "${A[@]}" shell "test -d $D/wav/cmd-$L" || "${A[@]}" push -q "$TS/cmd-$L" $D/wav/
  "${A[@]}" shell "cd $D && {
      free -m | sed -n 2p; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
      systemd-run --wait --pipe --unit=asrq-$TAG-$L -p Nice=5 -p MemoryMax=$MEM -p MemorySwapMax=0 \
          -p OOMScoreAdjust=900 $D/bin/$BIN --num-threads=$TH ${ARGS[*]} \$(ls $D/wav/cmd-$L/*.wav) 2>&1
      echo rc \$?
      systemctl is-active straylight-listen
    } > $D/log-$TAG-$L 2>&1"
  "${A[@]}" pull -q $D/log-$TAG-$L "$OUT/$TAG-$L.log"
  grep -E 'RTF|Elapsed|Memory peak|CPU time|^rc|active' "$OUT/$TAG-$L.log" | tail -6
done
