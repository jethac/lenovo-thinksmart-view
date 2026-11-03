#!/usr/bin/env bash
# One locked device session: stop straylight-listen, force xruns on the
# QDSP6 capture (hw:0,1) and playback (hw:0,0) PCMs with build/xrun-test,
# try recover and reopen, then start the listener again. Run it as
#   flock -w 1800 .device.lock streams/audio-dsp/session-xrun.sh OUTDIR [TEST...]
# where TEST is DIR:MODE[:CYCLES[:block]], e.g. "capture:plain",
# "capture:recover:10:block" (default: the full order below, riskiest last). The listener is down for well under a
# minute; playback writes silence only.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?outdir}; shift
mkdir -p "$OUT"
A=(adb -s feb0bd1f028e4cb0)
tests=("$@")
((${#tests[@]})) || tests=(capture:plain capture:reopen playback:plain playback:reopen
    playback:recover playback:plain capture:recover capture:plain playback:plain)
log() { echo "$*" | tee -a "$OUT/session.log"; }

"${A[@]}" push "$HERE/build/xrun-test" /root/xrun-test >/dev/null || exit 1
"${A[@]}" shell 'echo audio-dsp: session start > /dev/kmsg; systemctl stop straylight-listen'
t0=$(date +%s)
log "listener stopped at $(date -Is)"
i=0
for t in "${tests[@]}"; do
    i=$((i+1)) m="audio-dsp: $i $t"
    IFS=: read -r dir mode cyc blk <<<"$t"
    env=; [[ ${blk:-} == block ]] && env=XRUN_BLOCK=1
    d=hw:0,1; [[ $dir == playback ]] && d=hw:0,0
    log "== $t ($d)"
    "${A[@]}" shell "echo $m > /dev/kmsg; $env timeout 40 /root/xrun-test $dir $d $mode ${cyc:-}; echo exit \$?" 2>&1 | tee -a "$OUT/session.log"
    "${A[@]}" shell "dmesg | sed -n '/$m\$/,\$p' | tail -n +2" 2>&1 | tee -a "$OUT/session.log"
    (( $(date +%s) - t0 > 120 )) && { log "time budget reached, stopping tests"; break; }
done
"${A[@]}" shell 'systemctl start straylight-listen; echo audio-dsp: session end > /dev/kmsg'
log "listener started at $(date -Is), down $(( $(date +%s) - t0 )) s"
sleep 8
"${A[@]}" shell 'systemctl is-active straylight-listen; journalctl -u straylight-listen --since "-20s" --no-pager | tail -8' 2>&1 | tee -a "$OUT/session.log"
