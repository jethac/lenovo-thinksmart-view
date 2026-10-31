#!/usr/bin/env bash
# The whole pipeline with speech, from files, on the tablet: wake word, ASR,
# a real ai& reply (straylight-aiand must be signed in), Kokoro, under the
# service's limits as a transient unit (the service is stopped meanwhile and
# started again). With TTS_DEVICE=pace (default) nothing is played aloud.
#
#   device-kokoro-e2e.sh TAG FILE.wav... [-- straylight-listen options]
#
# The WAVs are 16 kHz test requests (voice-pipeline work/testset/16k).
# Log: work/kokoro/device/e2e-TAG.log, with "mem TIME RSS_KIB RSSFILE_KIB MAJFLT MEMAVAILABLE_KIB"
# lines every 0.5 s.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
TAG=$1; shift
files=(); while (($#)) && [[ $1 != -- ]]; do files+=("$1"); shift; done
[[ ${1:-} == -- ]] && shift
ADB="adb -s ${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}"
D=/var/tmp/kokoro-e2e
LOG=$HERE/work/kokoro/device/e2e-$TAG.log
mkdir -p "$(dirname "$LOG")"
exec 9> "$PROJ/.device.lock"
flock -w 3600 9
$ADB shell "mkdir -p $D" </dev/null
args=""
for f in "${files[@]}"; do $ADB push -q "$f" $D/ </dev/null; args="$args --input $D/$(basename "$f")"; done
{
    echo "# $(date -Is) $TAG: $* (${#files[@]} files)"
    $ADB shell "systemctl stop straylight-listen; sleep 1; free -m;
        ( while true; do p=\$(systemctl show -p MainPID --value kokoro-e2e-$TAG 2>/dev/null); if [ -n \"\$p\" ] && [ \"\$p\" != 0 ]; then echo \"mem \$(date +%s.%N | cut -c1-14) \$(awk '/VmRSS|RssFile/{printf \"%s \", \$2}' /proc/\$p/status 2>/dev/null) \$(awk '{print \$12}' /proc/\$p/stat 2>/dev/null) \$(awk '/MemAvailable/{print \$2}' /proc/meminfo)\"; fi; sleep 0.5; done ) > /var/tmp/kokoro-e2e-mem.log 2>&1 &
        sampler=\$!
        systemd-run --wait --pipe --unit=kokoro-e2e-$TAG -p Nice=-10 -p MemoryMax=1750M -p MemorySwapMax=0 -p OOMScoreAdjust=500 \
            /usr/local/bin/straylight-listen $args --realtime --tts-device ${TTS_DEVICE:-pace} -v $* 2>&1;
        kill \$sampler; cat /var/tmp/kokoro-e2e-mem.log; rm -f /var/tmp/kokoro-e2e-mem.log;
        free -m; systemctl start straylight-listen; journalctl -k --since -30min | grep -i -E 'oom|killed process' || true" </dev/null
} > "$LOG" 2>&1
echo "$LOG: $(grep -c '"outcome"' "$LOG") utterances"
