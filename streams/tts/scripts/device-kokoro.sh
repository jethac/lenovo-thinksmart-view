#!/bin/bash
# Run a Kokoro command on the tablet under the device lock, in a systemd
# scope with a memory limit, detached (it survives an adbd restart).
#
#   device-kokoro.sh push                 copy the payload to /var/tmp/kokoro
#   device-kokoro.sh run TAG CMD...       run CMD in /var/tmp/kokoro, keep TAG.out/.err/.peak_kb
#   device-kokoro.sh pull TAG FILE...     fetch files from /var/tmp/kokoro into work/kokoro/device/TAG/
#   device-kokoro.sh clean                remove /var/tmp/kokoro
#
# Payload (push): BIN (straylight-listen, aarch64), ORTLIB (libonnxruntime.so,
# aarch64), the Kokoro ONNX models in work/kokoro/*.onnx, the voices,
# work/kokoro/*.tsv. MEMMAX (default 800M) caps each run; the installed
# straylight-listen service keeps running alongside unless the command stops it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
A=(adb -s "$SERIAL")
D=/var/tmp/kokoro
OUT=$HERE/work/kokoro/device
BIN=${BIN:-/home/jethac/Projects/straylight-voice/listen/target/aarch64-unknown-linux-gnu/release/straylight-listen}
ORTLIB=${ORTLIB:-$PROJ/streams/asr/downloads/sherpa/sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu/lib/libonnxruntime.so}

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi

push_if_changed() {  # local remote
  local l=$1 r=$2 ls rs
  ls=$(stat -c %s "$l"); rs=$("${A[@]}" shell "stat -c %s $r 2>/dev/null || echo -" </dev/null)
  [[ $ls == "$rs" ]] || "${A[@]}" push -q "$l" "$r" </dev/null
}

case $1 in
push)
  "${A[@]}" shell "mkdir -p $D/voices $D/data"
  push_if_changed "$BIN" $D/straylight-listen
  "${A[@]}" shell "chmod +x $D/straylight-listen"
  push_if_changed "$ORTLIB" $D/libonnxruntime.so
  for f in "$HERE"/work/kokoro/*.onnx "$HERE"/work/kokoro/*.tsv; do [[ -e $f ]] && push_if_changed "$f" $D/$(basename "$f"); done
  for f in "$HERE"/downloads/kokoro/onnx-community/voices/{af_heart,af_bella,af_sarah,af_nicole,jf_alpha,jf_nezumi,jf_gongitsune,jf_tebukuro,zf_xiaobei,zf_xiaoni,zf_xiaoxiao,zf_xiaoyi}.bin; do
    push_if_changed "$f" $D/voices/$(basename "$f")
  done
  for f in ${EXTRA:-}; do
    if [[ -d $f ]]; then "${A[@]}" shell "mkdir -p $D/data/$(basename "$f")"; for g in "$f"/*; do push_if_changed "$g" $D/data/$(basename "$f")/$(basename "$g"); done
    else push_if_changed "$f" $D/data/$(basename "$f"); fi
  done
  "${A[@]}" shell "df -h /var/tmp | tail -1; du -sh $D"
  ;;
run)
  tag=$2; shift 2
  mkdir -p "$OUT/$tag"
  cmd=$(printf '%q ' "$@")
  cat > "$OUT/$tag/run.sh" <<RUN
cd $D && rm -f rc out err
systemd-run --scope -q -p MemoryMax=${MEMMAX:-800M} -p MemorySwapMax=0 $cmd > out 2> err &
p=\$!; peak=0
while kill -0 \$p 2>/dev/null; do v=\$(awk '/VmHWM/{print \$2}' /proc/\$p/status 2>/dev/null); [ -n "\$v" ] && [ "\$v" -gt \$peak ] && peak=\$v; sleep 0.2; done
wait \$p; r=\$?; echo \$peak > peak_kb
echo \$r > rc
RUN
  "${A[@]}" push -q "$OUT/$tag/run.sh" $D/run.sh </dev/null
  "${A[@]}" shell "rm -f $D/rc; setsid nohup sh $D/run.sh > /dev/null 2>&1 < /dev/null &" </dev/null
  until timeout 20 "${A[@]}" shell "test -s $D/rc" </dev/null 2>/dev/null; do sleep 2; done
  for s in out err rc peak_kb; do "${A[@]}" pull -q $D/$s "$OUT/$tag/$s" </dev/null; done
  echo "$tag: rc=$(cat "$OUT/$tag/rc") peak(sampled)=$(( $(cat "$OUT/$tag/peak_kb") / 1024 )) MiB"
  ;;
pull)
  tag=$2; shift 2; mkdir -p "$OUT/$tag"
  for f in "$@"; do "${A[@]}" pull -q "$D/$f" "$OUT/$tag/" </dev/null; done
  ;;
clean)
  "${A[@]}" shell "rm -rf $D"
  ;;
esac
