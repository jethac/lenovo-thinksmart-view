#!/bin/bash
# One-clip Qwen3-ASR run on the tablet with transcribe.cpp's perf breakdown
# (TRANSCRIBE_PERF_DEBUG), under the device lock. Uses /dev/shm, cleans up.
#
#   device-perf-qwen.sh QUANT THREADS WAV LANG
set -euo pipefail
Q=$1 T=$2 WAV=$3 L=$4
HERE=$(cd "$(dirname "$0")/.." && pwd); PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"); D=/dev/shm/asrperf
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then export TSV_DEVICE_LOCK_HELD=1; exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"; fi
"${A[@]}" shell "rm -rf $D && mkdir -p $D"; trap '"${A[@]}" shell "rm -rf $D" || true' EXIT
"${A[@]}" push -q "$HERE/work/build-a53/bin/transcribe-cli" "$HERE/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-$Q.gguf" "$WAV" $D/
"${A[@]}" shell "cd $D && TRANSCRIBE_PERF_DEBUG=1 ./transcribe-cli -m Qwen3-ASR-0.6B-$Q.gguf -l $L --threads $T $(basename "$WAV") 2>&1" | grep -A20 'perf breakdown' || true
