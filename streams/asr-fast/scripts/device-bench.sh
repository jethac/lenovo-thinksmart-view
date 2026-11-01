#!/bin/bash
# sla-bench (bench/sla-bench.cpp: straylight-listen's recogniser over WAV files
# in real time) on the tablet, next to the running straylight-listen: a
# transient unit with a memory cap, no swap, the service's priorities (Nice
# -10, recogniser worker at nice 5). sherpa-onnx v2.0.1 (its
# libsherpa-onnx-c-api.so and libonnxruntime.so) and the models live on the
# eMMC under /var/tmp/asrfast (pushed once); the VAD and Qwen3-ASR are the
# installed, read-only copies in /usr/local/share/straylight-listen (shared
# page cache with the service). Under the device lock.
#
#   device-bench.sh TAG SET [sla-bench options...]
#
# SET: cmd (the 45 command clips), phrase (the 33 phrase-set utterances) or
# both. In the options, @M/NAME is /var/tmp/asrfast/models/NAME (pushed from
# downloads/sherpa or ../asr/downloads/sherpa/models if missing), @Q the
# installed Qwen3-ASR GGUF, @L the sherpa-onnx C API library.
# IDS=REGEX limits the clips. MEM (default 700M) is the cap.
# Results: work/results/device/TAG.{jsonl,log}.
set -euo pipefail
TAG=$1; SET=$2; shift 2
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
SH=$PROJ/streams/asr/downloads/sherpa/sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu
TS=$PROJ/streams/asr/work/testset
BIN=$HERE/work/build-bench-aarch64/sla-bench
D=/var/tmp/asrfast
MD=/usr/local/share/straylight-listen
OUT=$HERE/work/results/device; mkdir -p "$OUT"
MEM=${MEM:-700M}
case $SET in
cmd) LISTS=("$TS"/cmd-{en,ja,zh}/refs.tsv) ;;
phrase) LISTS=("$TS"/phrase/refs.tsv) ;;
both) LISTS=("$TS"/cmd-{en,ja,zh}/refs.tsv "$TS"/phrase/refs.tsv) ;;
*) echo "SET: cmd, phrase or both" >&2; exit 2 ;;
esac
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$TAG" "$SET" "$@"
fi
"${A[@]}" shell "mkdir -p $D/bin $D/lib $D/models $D/wav"
"${A[@]}" shell "test -f $D/lib/libsherpa-onnx-c-api.so" || "${A[@]}" push -q "$SH"/lib/*.so $D/lib/
"${A[@]}" push -q "$BIN" $D/bin/ && "${A[@]}" shell "chmod 755 $D/bin/sla-bench"
ARGS=()
for x in "$@"; do
  if [[ $x == *@M/* ]]; then
    m=${x#*@M/}; m=${m%%/*}
    if ! "${A[@]}" shell "test -d $D/models/$m"; then
      src=$HERE/downloads/sherpa/$m; [[ -d $src ]] || src=$PROJ/streams/asr/downloads/sherpa/models/$m
      "${A[@]}" push -q "$src" $D/models/
    fi
  fi
  x=${x//@M\//$D/models/}; x=${x//@Q/$MD/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf}; x=${x//@L/$D/lib/libsherpa-onnx-c-api.so}
  ARGS+=("$x")
done
QARGS=$(printf '%q ' "${ARGS[@]}")  # through the device's shell as they are (e.g. a ';' in --online)
WAVS=""
for l in "${LISTS[@]}"; do
  sub=$(basename "$(dirname "$l")")
  "${A[@]}" shell "test -d $D/wav/$sub" || "${A[@]}" push -q "$(dirname "$l")" $D/wav/
  while IFS=$'\t' read -r id _ _; do
    [[ $id =~ ${IDS:-.} ]] || continue
    WAVS="$WAVS wav/$sub/$id.wav"
  done < "$l"
done
"${A[@]}" shell "cd $D && {
    echo freq \$(cat /sys/devices/system/cpu/cpu[04]/cpufreq/scaling_cur_freq | paste -sd' ')
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
    free -m; uptime
    echo listen-majflt \$(awk '{print \$12}' /proc/\$(pidof straylight-listen)/stat)
    systemd-run --wait --pipe --unit=asrb-$TAG --working-directory=$D \
        -p Nice=-10 -p MemoryMax=$MEM -p MemorySwapMax=0 -p OOMScoreAdjust=900 \
        $D/bin/sla-bench --vad $MD/silero-vad-v6.2-F32.gguf $QARGS $WAVS > out-$TAG.jsonl
    echo rc \$?
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
    free -m; uptime
    echo listen-majflt \$(awk '{print \$12}' /proc/\$(pidof straylight-listen)/stat)
    systemctl is-active straylight-listen
    journalctl -k --since -60min | grep -i -E 'oom|killed process' || true
  } > log-$TAG 2>&1"
"${A[@]}" pull -q $D/out-$TAG.jsonl "$OUT/$TAG.jsonl"
"${A[@]}" pull -q $D/log-$TAG "$OUT/$TAG.log"
"${A[@]}" shell "rm -f $D/out-$TAG.jsonl $D/log-$TAG"
grep -E '^rc |Memory peak|CPU time|oom' "$OUT/$TAG.log" || true
wc -l < "$OUT/$TAG.jsonl"
