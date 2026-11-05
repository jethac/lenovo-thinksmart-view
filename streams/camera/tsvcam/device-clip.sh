#!/bin/sh
# Run on the device (root) under the device lock: tsvcam clips on the Venus
# encoder, memory-capped beside the live services, and libx264 on the same
# kind of frames for comparison (ffmpeg from the private test prefix; test
# only, nothing on the tablet needs it). Video only. Clips are captures:
# copy them off and delete them.
#   device-clip.sh [OUT]      default /var/tmp/tsv-camcodec/out/clip
set -u
P=/var/tmp/tsv-camcodec
BIN=$P/bin/tsvcam
VF="--venc-flags ${VENC_FLAGS:-0}"
OUT=${1:-$P/out/clip}
rm -rf "$OUT"; mkdir -p "$OUT"
run() { systemd-run --quiet --wait --pipe --collect -p MemoryMax=200M -E LD_LIBRARY_PATH=$P/bin "$@" 2>&1; }
"$BIN" cover || exit 3
echo "== before: $(cat /proc/loadavg); listen rss $(ps -o rss= -C straylight-listen) KiB; $(free -m | awk '/Mem/{print "avail "$7" MiB"}')"
echo "== clip, defaults (5 s, threshold 0.12, heartbeat 1 s, 30 frames, 1100 KiB)"
run "$BIN" clip $VF -v -o "$OUT/default.mp4"
echo "== clip, every frame (threshold 0): 30 frames in 5 s"
run "$BIN" clip $VF --threshold 0 -v -o "$OUT/all.mp4" | grep -v "tsvcam:   "
echo "== clip, every frame, real timestamps"
run "$BIN" clip $VF --threshold 0 --real-time -o "$OUT/all-real.mp4" | grep -v "tsvcam:   "
echo "== capture + NV12 only (30 frames), the cost both encoders share"
run sh -c "$BIN stream --fps 6 -n 30 --nv12 -o - > /dev/null" | tail -2
for p in ultrafast veryfast; do
  echo "== capture + libx264 $p (1 thread), 30 frames at 6 fps"
  run sh -c "$BIN stream --fps 6 -n 30 --nv12 -o - 2>$OUT/x264-$p.log | $P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s 490x652 -r 6 -i pipe:0 -threads 1 -c:v libx264 -preset $p -b:v 1500k -y $OUT/x264-$p.mp4" | grep "bench:"
  tail -1 $OUT/x264-$p.log
done
for f in "$OUT"/*.mp4; do
  echo "$(basename $f): $(LD_LIBRARY_PATH=$P/bin $P/bin/ffprobe -v error -count_frames -show_entries stream=codec_name,profile,width,height,nb_read_frames,duration -of csv=p=0 $f) $(stat -c %s $f) bytes"
done
echo "== after: $(cat /proc/loadavg); listen rss $(ps -o rss= -C straylight-listen) KiB"
