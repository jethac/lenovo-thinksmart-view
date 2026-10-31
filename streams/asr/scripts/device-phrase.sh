#!/bin/bash
# Phrase-by-phrase transcription on the tablet (phrase/phrase-stream, Qwen3-ASR
# Q4_K_M with the Q8_0 conv stem, Silero VAD) over work/testset/phrase, audio
# fed at real-time pace. Under the device lock; model and audio go to /dev/shm
# and are removed afterwards.
#
#   device-phrase.sh TAG [phrase-stream options...]
#
# PHRASE_IDS=REGEX limits the run to matching utterance ids.
# Results: work/results/phrase/device-TAG.{jsonl,log}. Summarise with
# scripts/phrase-summary.py.
set -euo pipefail
TAG=$1; shift
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
ASR=$HERE/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf
VAD=$HERE/downloads/models/silero-vad-v6.2/silero-vad-v6.2-F32.gguf
BIN=$HERE/work/build-phrase-a53/bin/phrase-stream
SET=$HERE/work/testset/phrase
OUT=$HERE/work/results/phrase; mkdir -p "$OUT"
D=/dev/shm/asrphrase

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$TAG" "$@"
fi

"${A[@]}" shell "rm -rf $D && mkdir -p $D/wav"
trap '"${A[@]}" shell "rm -rf $D" || true' EXIT
"${A[@]}" push -q "$BIN" "$ASR" "$VAD" $D/
"${A[@]}" push -q "$SET"/*.wav $D/wav/
WAVS=$(cut -f1 "$SET/refs.tsv" | grep -E "${PHRASE_IDS:-.}" | sed "s|^|wav/|; s|\$|.wav|" | paste -sd' ')
"${A[@]}" shell "cd $D && {
    echo freq \$(cat /sys/devices/system/cpu/cpu[04]/cpufreq/scaling_cur_freq | paste -sd' ')
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
    ./phrase-stream -m $(basename "$ASR") --vad $(basename "$VAD") $* $WAVS > out.jsonl
    echo rc \$?
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
  } > log 2>&1"
"${A[@]}" pull -q $D/out.jsonl "$OUT/device-$TAG.jsonl"
"${A[@]}" pull -q $D/log "$OUT/device-$TAG.log"
grep -E '^rc ' "$OUT/device-$TAG.log"
wc -l < "$OUT/device-$TAG.jsonl"
