#!/bin/bash
# Benchmark Qwen3-ASR (transcribe.cpp, static aarch64) on the tablet, under the
# device lock. Model and clips go to /dev/shm (RAM) and are removed afterwards.
#
#   device-bench-qwen.sh QUANT THREADS [LANGS]      e.g. Q4_K_M 4 "en ja zh"
set -euo pipefail
Q=$1 T=$2 LANGS=${3:-"en ja zh"}
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
A=(adb -s "$SERIAL")
MODEL=$HERE/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-$Q.gguf
BIN=$HERE/work/build-a53/bin/transcribe-cli
OUT=$HERE/work/results/device; mkdir -p "$OUT"
D=/dev/shm/asr

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi

"${A[@]}" shell "rm -rf $D && mkdir -p $D/clips"
"${A[@]}" push -q "$BIN" "$MODEL" $D/
for l in $LANGS; do
  "${A[@]}" shell "mkdir -p $D/clips/$l"
  "${A[@]}" push -q "$HERE"/work/testset/cmd-$l/*.wav $D/clips/$l/
done
trap '"${A[@]}" shell "rm -rf $D" || true' EXIT

for l in $LANGS; do
  tag="qwen3-$Q-t$T-cmd-$l"
  "${A[@]}" shell "cd $D && ls clips/$l/*.wav > $l.list
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4 > $l.temp0
    cat /sys/devices/system/cpu/cpu[04]/cpufreq/scaling_cur_freq | paste -sd' ' > $l.freq0
    ./transcribe-cli -q -m Qwen3-ASR-0.6B-$Q.gguf -l $l --threads $T --batch $l.list --batch-jsonl > $l.jsonl 2> $l.err &
    p=\$!; peak=0
    while kill -0 \$p 2>/dev/null; do v=\$(awk '/VmHWM/{print \$2}' /proc/\$p/status 2>/dev/null); [ -n \"\$v\" ] && [ \$v -gt \$peak ] && peak=\$v; sleep 0.2; done
    wait \$p; echo \$? > $l.rc; echo \$peak > $l.peak_kb
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4 > $l.temp1"
  for s in jsonl err rc peak_kb temp0 temp1 freq0; do "${A[@]}" pull -q $D/$l.$s "$OUT/$tag.$s"; done
  echo "$tag: rc=$(cat "$OUT/$tag.rc") peak=$(( $(cat "$OUT/$tag.peak_kb") / 1024 )) MiB"
done
