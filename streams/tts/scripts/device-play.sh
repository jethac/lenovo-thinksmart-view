#!/bin/bash
# Play one short sample through the tablet's speaker via PipeWire at a modest
# level (sink volume 0.3 = amp -31 dB; never above), then restore the volume.
# Under the device lock. The image has no login session over adb, so the script
# starts jethac's user manager and PipeWire for the test if they are not running
# and stops what it started afterwards.
#
#   device-play.sh WAV
set -euo pipefail
WAV=$(realpath "$1")
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi
"${A[@]}" push -q "$WAV" /dev/shm/tts-play.wav
"${A[@]}" shell 'chmod 644 /dev/shm/tts-play.wav
U="runuser -u jethac -- env XDG_RUNTIME_DIR=/run/user/1000"
started=0
if ! systemctl is-active -q user@1000.service; then systemctl start user@1000.service; started=1; fi
$U systemctl --user start pipewire.socket pipewire wireplumber; sleep 4
amixer -c0 scontrols | grep -i -E "amp|speaker"
$U wpctl status | sed -n "/Sinks:/,/Sources:/p" | head -6
before=$($U wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk "{print \$2}")
echo "volume before: $before"
$U wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.30
$U wpctl get-volume @DEFAULT_AUDIO_SINK@
amixer -c0 sget "Speaker Amp Digital" 2>/dev/null | tail -2
t0=$(date +%s%N); $U pw-play /dev/shm/tts-play.wav; echo "pw-play rc=$? in $(( ($(date +%s%N)-t0)/1000000 )) ms"
$U wpctl set-volume @DEFAULT_AUDIO_SINK@ "$before"; echo "volume restored: $($U wpctl get-volume @DEFAULT_AUDIO_SINK@)"
if [ $started = 1 ]; then $U systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire wireplumber pipewire-pulse; systemctl stop user@1000.service; fi
echo "user manager: $(systemctl is-active user@1000.service)"
rm -f /dev/shm/tts-play.wav
dmesg | tail -5 | grep -i -E "tas5782|asoc|error" || true'
