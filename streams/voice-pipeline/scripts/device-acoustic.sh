#!/usr/bin/env bash
# Acoustic path: test utterances (wake word + command, 48 kHz stereo from
# work/testset/48k) played through the tablet's own speaker while the
# installed straylight-listen.service listens on its microphones. Each clip
# is played once (aplay -D hw:0,0), then the script waits for the service to
# log the utterance (or 45 s) before the next. Speaker amp at 187 (-10 dB, as
# the wake-word loopback test), restored afterwards. Under the device lock.
#
#   device-acoustic.sh TAG [IDS-GLOB]       default IDS-GLOB '{en,ja,zh}-0[0-4]' (15 clips)
#
# Log: work/results/TAG.log ("# clip ID" lines, each followed by the
# service's utterance line, if any).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
TAG=$1; GLOB=${2:-'{en,ja,zh}-0[0-4]'}
ADB="adb -s feb0bd1f028e4cb0"
LOG=$S/work/results/$TAG.log
D=/var/tmp/vp-48k
mkdir -p "$S/work/results"
files=$(cd "$S/work/testset/48k" && eval "ls $GLOB.wav")
exec 9> /home/jethac/Projects/lenovo-8/.device.lock
flock -w 1800 9
$ADB shell "rm -rf $D; mkdir -p $D"
for f in $files; do $ADB push "$S/work/testset/48k/$f" "$D/" > /dev/null 2>&1; done
cat > "$S/work/tmp/acoustic.sh" <<'SH'
set -u
D=$1
AMP='Speaker Amp Digital Playback Volume'
old=$(amixer -c0 cget name="$AMP" | sed -n 's/.*: values=\([0-9]*\).*/\1/p')
trap 'amixer -q -c0 cset name="$AMP" $old' EXIT
amixer -q -c0 cset name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1
amixer -q -c0 cset name="$AMP" 187
systemctl is-active -q straylight-listen || { echo "service not running"; exit 1; }
for f in $D/*.wav; do
    id=$(basename $f .wav)
    echo "# clip $id $(date +%s.%N)"
    c=$(journalctl -u straylight-listen -n 0 --show-cursor -q | sed -n 's/^-- cursor: //p')
    aplay -q -D hw:0,0 $f
    for i in $(seq 1 90); do
        l=$(journalctl -u straylight-listen --after-cursor="$c" -o cat -q | grep -E 'utterance|wake at' )
        case $l in *utterance*) break ;; esac
        sleep 0.5
    done
    echo "$l"
    sleep 1
done
echo "# amp back to $old"
grep -E 'VmRSS|VmHWM' /proc/$(systemctl show -p MainPID --value straylight-listen)/status
journalctl -k --since -30min | grep -i -E 'oom|killed process' || true
SH
$ADB push "$S/work/tmp/acoustic.sh" /var/tmp/acoustic.sh > /dev/null
{
    echo "# $(date -Is) $TAG: $(echo $files | wc -w) clips"
    $ADB shell "sh /var/tmp/acoustic.sh $D; rm -rf $D /var/tmp/acoustic.sh"
} > "$LOG" 2>&1
echo "$LOG: $(grep -c '"outcome"' "$LOG") utterances"
