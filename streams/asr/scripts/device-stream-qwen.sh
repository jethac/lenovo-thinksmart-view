#!/bin/bash
# Latency after the end of speech on the tablet, offline vs streaming
# (incremental conv stem), under the device lock. Each clip is "spoken" in
# real time: the streaming run feeds CHUNK_MS slices as they would arrive from
# a microphone, the offline run waits for the whole clip and then transcribes.
# transcribe-cli --stream-realtime reports latency_ms (end of audio to final
# text) and CPU time during/after the audio. A wake-up probe (scripts/wakeprobe)
# runs alongside every run and once idle, to show what the work does to
# another thread's responsiveness. Model, clips and binaries go to /dev/shm and
# are removed afterwards.
#
#   device-stream-qwen.sh QUANT THREADS [LANGS] [CHUNK_MS]
#
# Results: work/results/device/stream-QUANT-tT-LANG-{offline,stream}.{jsonl,err,probe}
# and idle.probe; summarise with scripts/summarise-stream.py.
set -euo pipefail
Q=$1 T=$2 LANGS=${3:-"en ja zh"} C=${4:-160}
HERE=$(cd "$(dirname "$0")/.." && pwd); PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"); D=/dev/shm/asrstream
OUT=$HERE/work/results/device; mkdir -p "$OUT"
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then export TSV_DEVICE_LOCK_HELD=1; exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"; fi
"${A[@]}" shell "rm -rf $D && mkdir -p $D/clips"; trap '"${A[@]}" shell "pkill -x wakeprobe; rm -rf $D" || true' EXIT
"${A[@]}" push -q "$HERE/work/build-a53/bin/transcribe-cli" "$HERE/work/build-a53/bin/wakeprobe" \
    "$HERE/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-$Q.gguf" $D/
"${A[@]}" shell "cd $D && ./wakeprobe 10 30 idle.probe.raw > idle.probe"
"${A[@]}" pull -q $D/idle.probe "$OUT/stream-idle.probe"
"${A[@]}" pull -q $D/idle.probe.raw "$OUT/stream-idle.probe.raw"
for l in $LANGS; do
  "${A[@]}" shell "mkdir -p $D/clips/$l"
  "${A[@]}" push -q "$HERE"/work/testset/cmd-$l/*.wav $D/clips/$l/
  for mode in offline stream; do
    tag="stream-$Q-t$T-$l-$mode"
    extra=""; [[ $mode == stream ]] && extra="--stream-chunk-ms $C"
    "${A[@]}" shell "cd $D && ls clips/$l/*.wav > $l.list
      ./wakeprobe 10 0 $tag.probe.raw > $tag.probe & p=\$!
      TRANSCRIBE_PERF_DEBUG=1 ./transcribe-cli -m Qwen3-ASR-0.6B-$Q.gguf -l $l --threads $T --batch $l.list --batch-jsonl --stream-realtime $extra > $tag.jsonl 2> $tag.err
      echo \$? > $tag.rc; kill -INT \$p; wait \$p"
    for s in jsonl err rc probe probe.raw; do "${A[@]}" pull -q $D/$tag.$s "$OUT/$tag.$s"; done
    echo "$tag: rc=$(cat "$OUT/$tag.rc") probe: $(cat "$OUT/$tag.probe")"
  done
done
