#!/bin/bash
# Bit-exactness of the prompt-prefix cache (patches/0003) on the tablet:
# transcribe-cli (work/build-a53) over a few command clips per language in
# batch mode (one session, so later clips find the earlier prompt in the
# cache), with the cache off (the 0001+0002 path), on, on through the
# streaming API (the prefix is prefilled at stream begin and, for long
# prompts, again during the audio), each also with a context prompt; header
# draft off. TRANSCRIBE_PERF_DEBUG logs the max logit after each prompt
# (l0=, hex), compared by scripts/prefix-check.py. Models: the installed,
# read-only copies; a transient unit with a memory cap; under the device lock.
# Results: work/results/device/prefix-check-LANG-MODE.{jsonl,err}.
#
#   device-prefix-check.sh [N_CLIPS] [LANGS]     defaults: 4, "en ja zh"
set -euo pipefail
N=${1:-4}; LANGS=${2:-"en ja zh"}
HERE=$(cd "$(dirname "$0")/.." && pwd); PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"); D=/dev/shm/asrpcheck
MD=/usr/local/share/straylight-listen
OUT=$HERE/work/results/device; mkdir -p "$OUT"
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then export TSV_DEVICE_LOCK_HELD=1; exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"; fi
"${A[@]}" shell "rm -rf $D && mkdir -p $D"; trap '"${A[@]}" shell "rm -rf $D" || true' EXIT
"${A[@]}" push -q "$HERE/work/build-a53/bin/transcribe-cli" $D/
P="今日は天気の話をしましょう。Let us talk about the weather today."
for l in $LANGS; do
  "${A[@]}" shell "mkdir -p $D/$l"
  for w in $(cut -f2 "$HERE/work/testset/cmd-$l/refs.tsv" | head -n "$N"); do "${A[@]}" push -q "$w" $D/$l/; done
  "${A[@]}" shell "cd $D && ls $l/*.wav > $l.list"
  for mode in off on son ctxoff ctxon ctxson; do
    e="TRANSCRIBE_QWEN3_NO_HEADER_DRAFT=1"; x=""
    case $mode in off|ctxoff) e="TRANSCRIBE_QWEN3_NO_PREFIX_CACHE=1" ;; esac
    case $mode in son|ctxson) x="--stream-chunk-ms 160" ;; esac
    case $mode in ctx*) x="$x --prompt '$P'" ;; esac
    "${A[@]}" shell "cd $D && systemd-run --quiet --wait --pipe -p MemoryMax=${MEM:-800M} -p MemorySwapMax=0 -p OOMScoreAdjust=900 \
        --working-directory=$D -E TRANSCRIBE_PERF_DEBUG=1 -E $e \
        ./transcribe-cli -m $MD/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf --threads 6 --batch $l.list --batch-jsonl $x > $l-$mode.jsonl 2> $l-$mode.err"
    "${A[@]}" pull -q $D/$l-$mode.jsonl "$OUT/prefix-check-$l-$mode.jsonl"
    "${A[@]}" pull -q $D/$l-$mode.err "$OUT/prefix-check-$l-$mode.err"
  done
done
