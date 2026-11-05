#!/bin/sh
# Run on the device (root) under the device lock: tsvcam stream and stills,
# memory-capped, beside the live services. Frames go to $OUT (captures: keep
# them off the repository).
#   device-bench.sh [OUT]       default /var/tmp/tsv-camcodec/out/bench
set -u
BIN=$(dirname "$(readlink -f "$0")")/tsvcam
OUT=${1:-/var/tmp/tsv-camcodec/out/bench}
rm -rf "$OUT"; mkdir -p "$OUT/s-half" "$OUT/s-full" "$OUT/s-crop"
run() { systemd-run --quiet --wait --pipe --collect -p MemoryMax=200M "$@" 2>&1 | grep -v "^tsvcam: seq"; }
"$BIN" cover || exit 3
echo "== before: $(cat /proc/loadavg); listen rss $(ps -o rss= -C straylight-listen) KiB; $(free -m | awk '/Mem/{print "avail "$7" MiB"}')"
echo "== stream 1304x980 binned -> 490x652 (quad), 6 fps, 60 frames"
run "$BIN" stream --fps 6 -n 60 -o "$OUT/s-half"
echo "== stream 1304x980 binned -> 980x1304 (demosaic), 6 fps, 30 frames"
run "$BIN" stream --fps 6 -n 30 --full -o "$OUT/s-full"
echo "== stream 1936x1096 crop -> 548x968 (quad), 6 fps, 30 frames"
run "$BIN" stream --mode crop --fps 6 -n 30 -o "$OUT/s-crop"
echo "== stream 1304x980 binned, unthrottled, 60 frames, no output"
run "$BIN" stream --fps 0 -n 60
echo "== photo full 1960x2608"
run "$BIN" photo -o "$OUT/photo-full.jpg"
echo "== photo half 980x1304"
run "$BIN" photo --half -o "$OUT/photo-half.jpg"
echo "== after: $(cat /proc/loadavg); listen rss $(ps -o rss= -C straylight-listen) KiB"
ls -la "$OUT"
