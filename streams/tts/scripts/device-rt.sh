#!/bin/bash
# Real-time TTS bake-off on the tablet: sherpa-onnx's offline TTS CLI (and the
# VOICEVOX bench) under the device lock, in a memory-capped systemd scope,
# detached, with the installed straylight-listen left running.
#
#   device-rt.sh base                     sherpa-onnx v2.0.1 aarch64 bin + libs -> /var/tmp/rt
#   device-rt.sh model DIR                one model directory -> /dev/shm/rt/<name> (others removed)
#   device-rt.sh run TAG CMD...           run CMD in /var/tmp/rt; keeps TAG.out/.err/peak_kb
#   device-rt.sh clean                    remove /var/tmp/rt and /dev/shm/rt
#
# MEMMAX (default 700M) caps each run. Results in work/rt/device/TAG/.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
A=(adb -s "$SERIAL")
D=/var/tmp/rt
M=/dev/shm/rt
OUT=$HERE/work/rt/device
SHERPA=${SHERPA:-$PROJ/streams/asr/downloads/sherpa/sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu}

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi

case $1 in
base)
  "${A[@]}" shell "mkdir -p $D/lib $D/bin"
  "${A[@]}" push -q "$SHERPA"/lib/*.so $D/lib/ </dev/null
  "${A[@]}" push -q "$SHERPA"/bin/sherpa-onnx-offline-tts $D/bin/ </dev/null
  for f in ${EXTRA:-}; do "${A[@]}" push -q "$f" $D/ </dev/null; done
  "${A[@]}" shell "chmod +x $D/bin/* 2>/dev/null; du -sh $D"
  ;;
model)
  src=$2
  "${A[@]}" shell "rm -rf $M; mkdir -p $M"
  "${A[@]}" push -q "$src" $M/ </dev/null
  "${A[@]}" shell "du -sh $M/*; free -m | sed -n 2p"
  ;;
run)
  tag=$2; shift 2
  mkdir -p "$OUT/$tag"
  cmd=$(printf '%q ' "$@")
  cat > "$OUT/$tag/run.sh" <<RUN
cd $D && rm -f rc out err
export LD_LIBRARY_PATH=$D/lib
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
  echo "$tag: rc=$(cat "$OUT/$tag/rc") peak=$(( $(cat "$OUT/$tag/peak_kb") / 1024 )) MiB"
  ;;
pull)
  tag=$2; shift 2; mkdir -p "$OUT/$tag"
  for f in "$@"; do "${A[@]}" pull -q "$D/$f" "$OUT/$tag/" </dev/null; done
  ;;
clean)
  "${A[@]}" shell "rm -rf $D $M"
  ;;
esac
