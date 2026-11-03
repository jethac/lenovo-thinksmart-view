#!/bin/bash
# A distilled voice through straylight-listen's own speech path on the tablet
# (--say-file, pacing sink: nothing is played), in a memory-capped transient
# scope next to the running service, under the device lock. Everything lives
# in /dev/shm/distil (the root file system is nearly full); the installed
# share supplies Kokoro, the front-end data and the lexicon.
#
#   device-distil.sh push BIN VOICE_DIR KIND/NAME  binary and voice -> /dev/shm/distil/share/KIND/NAME
#                                              (KIND matcha or paradee)
#   device-distil.sh run TAG LINES [ARGS...]   one --say-file run (--tts-voice en=KIND:NAME
#                                              in ARGS); results in work/device/TAG/
#   device-distil.sh stats                     the service's capture stats lines (last 15 min)
#   device-distil.sh clean                     remove /dev/shm/distil
#
# MEMMAX (default 700M) caps the run; RUNENV ("A=1 B=2") is put in its environment;
# KEEP (default en) the languages loaded at start.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
D=/dev/shm/distil
OUT=$HERE/work/device
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 1800 "$PROJ/.device.lock" "$0" "$@"
fi
case $1 in
push)
  bin=$2 voice=$3 name=$4
  "${A[@]}" shell "rm -rf $D/share/$name && mkdir -p $D/share/$name" </dev/null
  "${A[@]}" push -q "$bin" $D/straylight-listen </dev/null
  for f in "$voice"/*; do "${A[@]}" push -q "$f" $D/share/$name/ </dev/null; done
  "${A[@]}" shell "chmod +x $D/straylight-listen; du -sh $D/share/$name; df -h /dev/shm | tail -1; free -m | sed -n 2p" </dev/null
  ;;
run)
  tag=$2 lines=$3; shift 3
  mkdir -p "$OUT/$tag"
  "${A[@]}" push -q "$lines" $D/say.tsv </dev/null
  cmd=$(printf '%q ' env ${RUNENV:-} ./straylight-listen --say-file say.tsv --tts-device pace --tts-share $D/share --tts-keep ${KEEP:-en} -v "$@")
  cat > "$OUT/$tag/run.sh" <<RUN
cd $D && rm -f rc out err
systemd-run --scope -q -p MemoryMax=${MEMMAX:-700M} -p MemorySwapMax=0 nice -n 5 $cmd > out 2> err &
p=\$!; peak=0
while kill -0 \$p 2>/dev/null; do for q in \$(pgrep -P \$p) \$p; do v=\$(awk '/VmHWM/{print \$2}' /proc/\$q/status 2>/dev/null); [ -n "\$v" ] && [ "\$v" -gt \$peak ] && peak=\$v; done; sleep 0.2; done
wait \$p; r=\$?; echo \$peak > peak_kb
echo \$r > rc
RUN
  "${A[@]}" push -q "$OUT/$tag/run.sh" $D/run.sh </dev/null
  "${A[@]}" shell "rm -f $D/rc; setsid nohup sh $D/run.sh > /dev/null 2>&1 < /dev/null &" </dev/null
  until timeout 20 "${A[@]}" shell "test -s $D/rc" </dev/null 2>/dev/null; do sleep 2; done
  for s in out err rc peak_kb; do "${A[@]}" pull -q $D/$s "$OUT/$tag/$s" </dev/null; done
  for p in $("${A[@]}" shell "ls $D/prof_*.json 2>/dev/null" </dev/null | tr -d '\r'); do "${A[@]}" pull -q "$p" "$OUT/$tag/" </dev/null; "${A[@]}" shell "rm -f $p" </dev/null; done
  echo "$tag: rc=$(cat "$OUT/$tag/rc") peak=$(( $(cat "$OUT/$tag/peak_kb") / 1024 )) MiB"
  ;;
stats)
  "${A[@]}" shell "journalctl -u straylight-listen --no-pager --since '-15 min' | grep -o 'straylight-listen: cpu.*' | tail -3" </dev/null
  ;;
clean)
  "${A[@]}" shell "rm -rf $D; free -m | sed -n 2p" </dev/null
  ;;
esac
