#!/bin/bash
# Qwen3-ASR perf breakdown (TRANSCRIBE_PERF_DEBUG) over whole test sets on the
# tablet, under the device lock. Model and clips go to /dev/shm and are removed
# afterwards. Writes work/results/device/perf-set-QUANT-tT-LANG.err.
#
#   device-perf-set-qwen.sh QUANT THREADS [LANGS]     e.g. Q4_K_M-convq8 8 "en ja zh"
set -euo pipefail
Q=$1 T=$2 LANGS=${3:-"en ja zh"}
HERE=$(cd "$(dirname "$0")/.." && pwd); PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"); D=/dev/shm/asrperf
OUT=$HERE/work/results/device; mkdir -p "$OUT"
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then export TSV_DEVICE_LOCK_HELD=1; exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"; fi
"${A[@]}" shell "rm -rf $D && mkdir -p $D/clips"; trap '"${A[@]}" shell "rm -rf $D" || true' EXIT
"${A[@]}" push -q "$HERE/work/build-a53/bin/transcribe-cli" "$HERE/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-$Q.gguf" $D/
for l in $LANGS; do
  "${A[@]}" shell "mkdir -p $D/clips/$l"
  "${A[@]}" push -q "$HERE"/work/testset/cmd-$l/*.wav $D/clips/$l/
  "${A[@]}" shell "cd $D && ls clips/$l/*.wav > $l.list && TRANSCRIBE_PERF_DEBUG=1 ./transcribe-cli -m Qwen3-ASR-0.6B-$Q.gguf -l $l --threads $T --batch $l.list --batch-jsonl > $l.jsonl 2> $l.err"
  "${A[@]}" pull -q $D/$l.err "$OUT/perf-set-$Q-t$T-$l.err"
  "${A[@]}" pull -q $D/$l.jsonl "$OUT/perf-set-$Q-t$T-$l.jsonl"
  echo "perf-set-$Q-t$T-$l: $(grep -c 'perf breakdown' "$OUT/perf-set-$Q-t$T-$l.err") runs"
done
