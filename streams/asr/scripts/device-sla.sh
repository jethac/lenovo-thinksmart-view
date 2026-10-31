#!/bin/bash
# straylight-listen's recogniser over WAV files on the tablet (phrase/sla-file,
# see its header; --modes off,prefix,draft compares the prompt-prefix cache
# modes), next to the running services: the models are the installed,
# read-only copies in /usr/local/share/straylight-listen (memory-mapped, so
# their page cache is shared with straylight-listen.service), audio and
# binary in /dev/shm
# (removed afterwards), and the run is its own transient unit with a memory cap
# and the service's priorities (Nice=-10, recogniser worker at nice 5). Under
# the device lock.
#
#   device-sla.sh TAG SET [sla-file options...]
#
# SET: cmd (the 45 command clips, work/testset/cmd-{en,ja,zh}) or phrase
# (work/testset/phrase). IDS=REGEX limits the run to matching clip ids.
# Results: work/results/sla/device-TAG.{jsonl,log}; summarise with
# scripts/sla-summary.py.
set -euo pipefail
TAG=$1; SET=$2; shift 2
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
BIN=$HERE/work/build-phrase-a53/bin/sla-file
MD=/usr/local/share/straylight-listen
OUT=$HERE/work/results/sla; mkdir -p "$OUT"
D=/dev/shm/asrsla
MEM=${SLA_MEMORY_MAX:-800M}

case $SET in
cmd) LISTS=("$HERE"/work/testset/cmd-{en,ja,zh}/refs.tsv) ;;
phrase) LISTS=("$HERE"/work/testset/phrase/refs.tsv) ;;
*) echo "SET: cmd or phrase" >&2; exit 2 ;;
esac

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$TAG" "$SET" "$@"
fi

"${A[@]}" shell "rm -rf $D && mkdir -p $D/wav"
trap '"${A[@]}" shell "systemctl stop sla-$TAG 2>/dev/null; rm -rf $D" || true' EXIT
"${A[@]}" push -q "$BIN" $D/
WAVS=""
for l in "${LISTS[@]}"; do
  sub=$(basename "$(dirname "$l")")
  "${A[@]}" shell "mkdir -p $D/wav/$sub"
  while IFS=$'\t' read -r id wav _; do
    [[ $id =~ ${IDS:-.} ]] || continue
    "${A[@]}" push -q "$wav" $D/wav/$sub/
    WAVS="$WAVS wav/$sub/$id.wav"
  done < "$l"
done
"${A[@]}" shell "cd $D && {
    echo freq \$(cat /sys/devices/system/cpu/cpu[04]/cpufreq/scaling_cur_freq | paste -sd' ')
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
    free -m; uptime
    echo listen-majflt \$(awk '{print \$12}' /proc/\$(pidof straylight-listen)/stat)
    systemd-run --quiet --wait --pipe --unit=sla-$TAG --working-directory=$D \
        -p Nice=-10 -p MemoryMax=$MEM -p MemorySwapMax=0 -p OOMScoreAdjust=900 \
        $D/sla-file -m $MD/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf --vad $MD/silero-vad-v6.2-F32.gguf $* $WAVS > out.jsonl
    echo rc \$?
    for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep -E 'cpu|apc' | head -4
    free -m; uptime
    echo listen-majflt \$(awk '{print \$12}' /proc/\$(pidof straylight-listen)/stat)
    systemctl is-active straylight-listen
    journalctl -k --since -60min | grep -i -E 'oom|killed process' || true
  } > log 2>&1"
"${A[@]}" pull -q $D/out.jsonl "$OUT/device-$TAG.jsonl"
"${A[@]}" pull -q $D/log "$OUT/device-$TAG.log"
grep -E '^rc ' "$OUT/device-$TAG.log"
wc -l < "$OUT/device-$TAG.jsonl"
