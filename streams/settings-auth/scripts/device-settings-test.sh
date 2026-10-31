#!/usr/bin/env bash
# One locked device session: every settings screen on the panel, driven by
# real taps (tools/tap.c from straylight-voice) and by straylight-voicectl,
# grabbed with straylight-voice --grab; then the listener's signed-out and
# Offline paths through the whole pipeline with a recorded request.
#
#   flock -w 1800 .device.lock streams/settings-auth/scripts/device-settings-test.sh OUTDIR
#
# Needs straylight-voice, -listen, -aiand and -wifi installed and running,
# and the tap tool built for aarch64 at work/tap. It runs one WPS
# push-button session for a few seconds and cancels it. It does not join
# any network and types no real password.
set -euo pipefail
OUT=${1:?OUTDIR}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/../work
DEMO=$HERE/../../voice-pipeline/work/testset/16k
S=feb0bd1f028e4cb0
mkdir -p "$OUT"
sh() { adb -s $S shell "$@"; }
ctl() { sh "straylight-voicectl '$1'"; }
tap() { sh "/var/tmp/sltap $1 $2"; }
n=0
grab() {
    n=$((n + 1))
    local f; f=$(printf '%02d-%s' $n "$1")
    sh "straylight-voice --grab /var/tmp/$f.ppm"
    adb -s $S pull /var/tmp/$f.ppm "$OUT/" > /dev/null
    sh "rm -f /var/tmp/$f.ppm"
    echo "grabbed $f"
}
log() { echo "== $*"; }

adb -s $S push "$WORK/tap" /var/tmp/sltap > /dev/null
sh "chmod 755 /var/tmp/sltap"
SINCE=$(sh "date '+%Y-%m-%d %H:%M:%S'" | tr -d '\r')

log "idle with the settings button"
ctl '{"overlay":"none"}'; ctl idle; sleep 2; grab idle

log "tap the settings button"
tap 692 94; sleep 1.5; grab home
ctl get

log "Sound (tap the row), then back"
tap 400 644; sleep 1.5; grab sound
tap 92 172; sleep 1

log "Microphone (live level from the listener)"
tap 400 800; sleep 2; grab microphone; sleep 0.5; grab microphone-2
tap 92 172; sleep 1

log "Wi-Fi (networks from NetworkManager)"
tap 400 488; sleep 7; grab wifi

log "Model, About"
ctl '{"overlay":"model"}'; sleep 1.5; grab model
ctl '{"overlay":"about"}'; sleep 1.5; grab about

log "the keyboard: 8 letters typed, then shown (no Join)"
ctl '{"overlay":"keyboard","ssid":"straylight-test-absent"}'; sleep 1.5; grab keyboard-empty
for x in 49 127 205 283 361 439 517 595; do tap $x 846; sleep 0.25; done
sleep 0.5; grab keyboard-typed
tap 676 434; sleep 0.8; grab keyboard-shown
tap 692 100; sleep 1

log "WPS: one push-button session, cancelled after a few seconds"
ctl '{"overlay":"wps"}'; sleep 4; grab wps-waiting
tap 168 1164; sleep 1.5; grab wps-cancelled

log "sign-in with no internet"
ctl '{"overlay":"account"}'; sleep 1.5; grab account
tap 192 1164; sleep 6; grab signin-error
ctl '{"overlay":"none"}'; sleep 1

log "Offline with the settings button, settings over it"
ctl '{"state":"offline"}'; sleep 1.5; grab offline
tap 692 94; sleep 1.5; grab offline-settings
ctl '{"overlay":"none"}'; ctl idle; sleep 1

log "CPU of the screen with settings open and still (5 s)"
ctl '{"overlay":"home"}'; sleep 2
sh 'p=$(pidof straylight-voice); a=$(awk "{print \$14+\$15}" /proc/$p/stat); sleep 5; b=$(awk "{print \$14+\$15}" /proc/$p/stat); echo "settings open, still: $(( (b - a) * 100 / 500 )) % of a core"'
ctl '{"overlay":"none"}'; sleep 2
sh 'p=$(pidof straylight-voice); a=$(awk "{print \$14+\$15}" /proc/$p/stat); sleep 5; b=$(awk "{print \$14+\$15}" /proc/$p/stat); echo "idle: $(( (b - a) * 100 / 500 )) % of a core"'

log "the whole pipeline with a recorded request (service stopped meanwhile)"
adb -s $S push "$DEMO/demo-en.wav" /var/tmp/demo-en.wav > /dev/null
sh "systemctl stop straylight-listen"
L="/usr/local/bin/straylight-listen --input /var/tmp/demo-en.wav --realtime"
log "1. signed out: Speaking says how to sign in"
sh "$L > /var/tmp/run1.log 2>&1 &"
for i in $(seq 1 40); do sleep 1; v=$(sh "straylight-voicectl get" | tr -d '\r'); case $v in *speaking*) break;; esac; done
sleep 1.5; grab speaking-signed-out
sleep 8; sh "cat /var/tmp/run1.log | grep -E 'request|ai&|reply|utterance' | cut -c1-300"
log "2. the ai& client stopped: Offline"
sh "systemctl stop straylight-aiand"
sh "$L > /var/tmp/run2.log 2>&1 &"
for i in $(seq 1 40); do sleep 1; v=$(sh "straylight-voicectl get" | tr -d '\r'); case $v in *offline*) break;; esac; done
sleep 1; grab offline-no-client
sleep 7; sh "grep -E 'no reply|request' /var/tmp/run2.log | cut -c1-200"
sh "systemctl start straylight-aiand"
log "3. settings open: the wake word is held"
ctl '{"overlay":"home"}'
sh "$L > /var/tmp/run3.log 2>&1"
sh "grep -E 'wake|settings' /var/tmp/run3.log | cut -c1-200"
ctl '{"overlay":"none"}'
sh "rm -f /var/tmp/demo-en.wav /var/tmp/run?.log /var/tmp/sltap"
sh "systemctl start straylight-listen"
sleep 3
sh "systemctl is-active straylight-voice straylight-listen straylight-aiand straylight-wifi"

log "journal since $SINCE"
sh "journalctl --since '$SINCE' -u straylight-voice -u straylight-listen -u straylight-aiand -u straylight-wifi --no-pager -o cat | grep -v -E 'live:|^$' | tail -80"
