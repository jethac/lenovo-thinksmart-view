#!/usr/bin/env bash
# File input through the whole pipeline on the tablet: straylight-listen
# --input --realtime over test utterances (wake word + command) from
# work/testset/16k, with the screen, as a transient unit with the service's
# limits. The service is stopped for the run (two copies of the models would
# not fit) and started again afterwards. Under the device lock.
#
#   device-file.sh TAG [IDS-GLOB] [straylight-listen options...]
#
# IDS-GLOB picks utterances (default '*': all 45; e.g. '{en,ja,zh}-0[0-4]').
# Log: work/results/TAG.log (stderr and stdout of the run, then the unit's
# resource summary).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
TAG=$1; GLOB=${2:-*}; shift 2 || shift $#
ADB="adb -s feb0bd1f028e4cb0"
mkdir -p "$S/work/results"
LOG=$S/work/results/$TAG.log
D=/var/tmp/vp-testset
files=$(cd "$S/work/testset/16k" && eval "ls $GLOB.wav")
exec 9> /home/jethac/Projects/lenovo-8/.device.lock
flock -w 1800 9
$ADB shell "mkdir -p $D"
n=$($ADB shell "ls $D | wc -l" | tr -d '\r')
[[ $n -ge 45 ]] || $ADB push "$S"/work/testset/16k/*.wav "$D/" > /dev/null 2>&1
args=""
for f in $files; do args="$args --input $D/$f"; done
{
    echo "# $(date -Is) $TAG: $* ($(echo $files | wc -w) files)"
    $ADB shell "systemctl stop straylight-listen; sleep 1; free -m;
        systemd-run --wait --pipe --unit=vp-file-$TAG -p Nice=-10 -p MemoryMax=1300M -p MemorySwapMax=0 -p OOMScoreAdjust=500 \
            /usr/local/bin/straylight-listen $args --realtime $* 2>&1;
        free -m; systemctl start straylight-listen; journalctl -k --since -30min | grep -i -E 'oom|killed process' || true"
} > "$LOG" 2>&1
echo "$LOG: $(grep -c '"outcome"' "$LOG") utterances"
