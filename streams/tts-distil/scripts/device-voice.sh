#!/bin/bash
# Try a distilled voice in the running service, under the device lock:
#   device-voice.sh install BIN VOICE_DIR KIND/NAME LANG
#       binary to /usr/local/bin (the old one kept as straylight-listen.prev),
#       voice to {share}/KIND/NAME, /etc/straylight-listen.conf's
#       --tts-voice LANG=... switched to KIND:NAME (old conf kept as .prev),
#       service restarted (about 35 s of downtime), first lines of its log
#   device-voice.sh revert KIND/NAME
#       conf and binary back from .prev, the voice removed, service restarted
#   device-voice.sh trial BIN VOICE_DIR KIND/NAME LANG
#       as install, but the voice lives in /dev/shm/distil-share (links to the
#       installed share plus the voice; the root file system is too full for
#       it): --tts-share and --tts-voice LANG=KIND:NAME added to the conf.
#       Temporary (tmpfs): revert with "revert-trial".
#   device-voice.sh revert-trial  conf and binary back from .prev, /dev/shm/distil-share removed
#   device-voice.sh mem           the service's memory (RSS, anon, file) and MemAvailable
set -euo pipefail
PROJ=$(cd "$(dirname "$0")/../../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
SH=/usr/local/share/straylight-listen
C=/etc/straylight-listen.conf
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 1800 "$PROJ/.device.lock" "$0" "$@"
fi
mem() {
  "${A[@]}" shell 'p=$(pidof straylight-listen); grep -E "VmRSS|RssAnon|RssFile" /proc/$p/status | tr -s " " | tr "\n" " "; grep MemAvailable /proc/meminfo' </dev/null
}
case $1 in
install)
  bin=$2 voice=$3 name=$4 lang=$5
  need=$(du -sk "$voice" | cut -f1)
  free=$("${A[@]}" shell "df -k / | tail -1" </dev/null | awk '{print $4}')
  echo "voice ${need} KiB, root free ${free} KiB"
  (( free - need > 100000 )) || { echo "not enough room on / (keeping 100 MB free)"; exit 1; }
  "${A[@]}" shell "mkdir -p $SH/$name /var/tmp/distil" </dev/null
  for f in "$voice"/*; do "${A[@]}" push -q "$f" $SH/$name/ </dev/null; done
  "${A[@]}" push -q "$bin" /var/tmp/distil/straylight-listen </dev/null
  "${A[@]}" shell "cp -n $C $C.prev; cp -n /usr/local/bin/straylight-listen /usr/local/bin/straylight-listen.prev; \
    install -m 755 /var/tmp/distil/straylight-listen /usr/local/bin/straylight-listen; rm -rf /var/tmp/distil; \
    sed -i 's|--tts-voice $lang=[^ ]*|--tts-voice $lang=${name/\//:}|' $C; grep ARGS $C; \
    systemctl restart straylight-listen; sleep 40; systemctl is-active straylight-listen; \
    journalctl -u straylight-listen --no-pager --since '-45 s' | grep -E 'tts|error' | tail -5" </dev/null
  mem
  ;;
revert)
  name=$2
  "${A[@]}" shell "test -f $C.prev && mv $C.prev $C; test -f /usr/local/bin/straylight-listen.prev && mv /usr/local/bin/straylight-listen.prev /usr/local/bin/straylight-listen; \
    rm -rf $SH/$name; grep ARGS $C; systemctl restart straylight-listen; sleep 40; systemctl is-active straylight-listen; df -h / | tail -1" </dev/null
  mem
  ;;
trial)
  bin=$2 voice=$3 name=$4 lang=$5
  T=/dev/shm/distil-share
  "${A[@]}" shell "rm -rf $T; mkdir -p $T/$name; for f in $SH/*; do ln -s \$f $T/; done; rm -f $T/${name%%/*}; mkdir -p $T/$name; ls $T" </dev/null
  for f in "$voice"/*; do "${A[@]}" push -q "$f" $T/$name/ </dev/null; done
  "${A[@]}" push -q "$bin" /dev/shm/straylight-listen.trial </dev/null
  "${A[@]}" shell "cp -n $C $C.prev; cp -n /usr/local/bin/straylight-listen /usr/local/bin/straylight-listen.prev; \
    install -m 755 /dev/shm/straylight-listen.trial /usr/local/bin/straylight-listen; rm -f /dev/shm/straylight-listen.trial; \
    sed -i 's|--tts-voice $lang=[^ ]*|--tts-share $T --tts-voice $lang=${name/\//:}|' $C; grep ARGS $C; \
    systemctl restart straylight-listen; sleep 45; systemctl is-active straylight-listen; \
    journalctl -u straylight-listen --no-pager --since '-50 s' | grep -E 'tts|error|rror' | tail -6" </dev/null
  mem
  ;;
revert-trial)
  "${A[@]}" shell "test -f $C.prev && mv $C.prev $C; test -f /usr/local/bin/straylight-listen.prev && mv /usr/local/bin/straylight-listen.prev /usr/local/bin/straylight-listen; \
    grep ARGS $C; systemctl restart straylight-listen; sleep 40; systemctl is-active straylight-listen; rm -rf /dev/shm/distil-share; df -h / | tail -1" </dev/null
  mem
  ;;
mem) mem ;;
esac
