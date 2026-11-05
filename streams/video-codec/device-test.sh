#!/bin/sh
# Run on the device (root, under the device lock) with a kernel that enables
# Venus (kernel/patches-wip/video-codec/0701). Tools from the private prefix
# /var/tmp/tsv-camcodec: ffmpeg/ffprobe/libx264 (build-ffmpeg.sh) and tsvcam
# (streams/camera/tsvcam). Every run is memory-capped and time-limited.
#
#   device-test.sh probe                 Venus probe log, nodes, formats
#   device-test.sh decode FILE...        hardware decode (frame counts, speed, CPU)
#   device-test.sh verify FILE...        hardware vs software decode, per-frame MD5 of NV12
#   device-test.sh encode-v4l2           Venus encode with v4l2-ctl alone, ioctl trace
#   device-test.sh reload                reload the Venus modules (fresh firmware session)
#   device-test.sh order FILE...         B-frame clips decoded in decode order (display delay 0)
#   device-test.sh encode-probe          encoder at 640x480 in H.264, HEVC and VP8 (v4l2-ctl)
#   device-test.sh encode-camera-x264 [N] camera -> tsvcam NV12 -> libx264 (CPU) for comparison
#   device-test.sh encode-sweep          encoder at several sizes (v4l2-ctl, then ffmpeg), buffer trace
#                                        (trace needs the debug-only venus-trace-bufs-debug.patch kernel)
#   device-test.sh traced NAME FWLEVEL CMD...  run CMD with venus_core.trace on and the firmware
#                                        log level FWLEVEL, kernel log streamed to $OUT/NAME.klog
#   device-test.sh cpudecode FILE...     the same with ffmpeg's software decoders
#   device-test.sh bframes FILE          B-frame stall with V4L2 ioctl and Venus traces
#   device-test.sh encode-synth          1080p30 H.264 encode, Venus vs libx264
#   device-test.sh encode-camera [N]     camera -> tsvcam NV12 -> Venus H.264, N frames at 6 fps
set -u
P=/var/tmp/tsv-camcodec
OUT=$P/out/codec
MEDIA=$P/media
mkdir -p $OUT
export LD_LIBRARY_PATH=$P/bin
FF="$P/bin/ffmpeg -hide_banner -nostdin"
# capped SECONDS CMD...: memory cap 300 MiB, killed after SECONDS (+5 s for SIGKILL)
capped() { t=$1; shift; systemd-run --quiet --wait --pipe --collect -p MemoryMax=300M \
	-p RuntimeMaxSec=$t -E LD_LIBRARY_PATH=$P/bin timeout -k 5 $t "$@"; }

node() {	# driver name -> /dev/videoN
	for n in /sys/class/video4linux/video*; do
		[ "$(cat $n/name)" = "$1" ] && echo /dev/$(basename $n)
	done | head -1
}

codec_of() { case "$1" in *hevc*) echo hevc ;; *) echo h264 ;; esac; }

frames() {	# count frames ffprobe can read from a file
	LD_LIBRARY_PATH=$P/bin $P/bin/ffprobe -v error -count_frames -select_streams v:0 \
		-show_entries stream=nb_read_frames,width,height,codec_name,profile -of csv=p=0 "$1"
}

probe() {
	dmesg | grep -iE "venus|qcom-venus" | tail -20
	for n in /sys/class/video4linux/video*; do echo "$(basename $n): $(cat $n/name)"; done
	D=$(node qcom-venus-decoder); E=$(node qcom-venus-encoder)
	echo "decoder $D encoder $E"
	[ -n "$D" ] && v4l2-ctl -d $D --list-formats-out-ext | grep -E "\[|Size" | head -20
	[ -n "$D" ] && v4l2-ctl -d $D --list-formats-ext | grep -E "\[" | head
	[ -n "$E" ] && v4l2-ctl -d $E --list-formats-out | grep -E "\[" | head
	[ -n "$E" ] && v4l2-ctl -d $E --list-formats | grep -E "\["
	cat /sys/kernel/debug/clk/video_core_clk/clk_rate 2>/dev/null
}

decode() {	# $1 = hw|sw, files...
	how=$1; shift
	for f in "$@"; do
		c=$(codec_of "$f")
		[ $how = hw ] && dec="-c:v ${c}_v4l2m2m" || dec=""
		echo "== $how decode $(basename $f) [$(frames $MEDIA/$f)]"
		capped 90 $P/bin/ffmpeg -hide_banner -nostdin -benchmark $dec -i $MEDIA/$f \
			-f null - > $OUT/dec-$how-$(basename $f .mp4).log 2>&1
		echo "exit $?"
		tr '\r' '\n' < $OUT/dec-$how-$(basename $f .mp4).log | grep -E "^frame=|bench:|rror" | tail -3
	done
}

reload() {
	rmmod venus_dec venus_enc 2>&1; rmmod venus_core 2>&1
	modprobe venus_core && modprobe venus_dec && modprobe venus_enc
	sleep 1; echo "venus modules: $(lsmod | grep -c ^venus)"
}

verify() {
	for f in "$@"; do
		c=$(codec_of "$f"); b=$(basename $f .mp4)
		reload >/dev/null
		capped 90 $P/bin/ffmpeg -hide_banner -nostdin -c:v ${c}_v4l2m2m -i $MEDIA/$f -pix_fmt nv12 \
			-y -f framemd5 $OUT/$b-hw.md5 > $OUT/verify-$b-hw.log 2>&1
		echo "hw exit $?"
		capped 90 $P/bin/ffmpeg -hide_banner -nostdin -i $MEDIA/$f -pix_fmt nv12 \
			-y -f framemd5 $OUT/$b-sw.md5 > $OUT/verify-$b-sw.log 2>&1
		grep -v '^#' $OUT/$b-hw.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$b-hw.h
		grep -v '^#' $OUT/$b-sw.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$b-sw.h
		echo "== verify $b: hw frames $(wc -l < $OUT/$b-hw.h), sw frames $(wc -l < $OUT/$b-sw.h)," \
			"hw frames bit-identical to a sw frame: $(sort $OUT/$b-hw.h | uniq | grep -cxFf $OUT/$b-sw.h)," \
			"same position: $(paste -d' ' $OUT/$b-hw.h $OUT/$b-sw.h | awk '$1==$2' | wc -l)," \
			"decode errors $(grep -c 'driver decode error' $OUT/verify-$b-hw.log)"
	done
}

encode_v4l2() {
	E=$(node qcom-venus-encoder)
	reload >/dev/null
	dmesg -C
	echo 3 > /sys/class/video4linux/$(basename $E)/dev_debug
	echo "== v4l2-ctl encode 1920x1080 NV12 -> H264, 30 frames on $E"
	capped 30 v4l2-ctl -d $E --set-fmt-video-out=width=1920,height=1080,pixelformat=NV12 \
		--set-fmt-video=width=1920,height=1080,pixelformat=H264 --stream-mmap --stream-out-mmap \
		--stream-from=$MEDIA/testsrc2-1080p-30f.nv12 --stream-to=$OUT/v4l2-enc.h264 --stream-count=30 2>&1 | tail -5
	echo "exit $?; output $(stat -c %s $OUT/v4l2-enc.h264 2>/dev/null) bytes, frames $(frames $OUT/v4l2-enc.h264)"
	echo 0 > /sys/class/video4linux/$(basename $E)/dev_debug
	dmesg > $OUT/enc-v4l2-dmesg.log
	grep -oE "VIDIOC_[A-Z_]+" $OUT/enc-v4l2-dmesg.log | sort | uniq -c | sort -rn | head
	grep -iE "venus|error|fail" $OUT/enc-v4l2-dmesg.log | grep -v VIDIOC | tail -10
	echo "== ffmpeg h264_v4l2m2m encode, 30 frames, verbose"
	reload >/dev/null
	capped 30 $P/bin/ffmpeg -hide_banner -nostdin -loglevel verbose -f rawvideo -pix_fmt nv12 -s 1920x1080 \
		-r 30 -i $MEDIA/testsrc2-1080p-30f.nv12 -c:v h264_v4l2m2m -b:v 8M -y $OUT/ffenc.mp4 > $OUT/ffenc.log 2>&1
	echo "exit $?; frames $(frames $OUT/ffenc.mp4)"
	tr '\r' '\n' < $OUT/ffenc.log | grep -vE "^frame=|^\s*$" | grep -iE "v4l2|error|warn" | tail -15
}

order() {
	for f in "$@"; do
		c=$(codec_of "$f"); b=$(basename $f .mp4)
		reload >/dev/null
		capped 60 env TSV_V4L2_DECODE_ORDER=1 $P/bin/ffmpeg -hide_banner -nostdin \
			-c:v ${c}_v4l2m2m -i $MEDIA/$f -pix_fmt nv12 -y -f framemd5 $OUT/$b-order.md5 > $OUT/order-$b.log 2>&1
		echo "hw exit $? (124 = timeout); $(grep -o 'decode order requested.*' $OUT/order-$b.log)"
		capped 90 $P/bin/ffmpeg -hide_banner -nostdin -i $MEDIA/$f -pix_fmt nv12 \
			-y -f framemd5 $OUT/$b-sw.md5 > /dev/null 2>&1
		grep -v '^#' $OUT/$b-order.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$b-order.h
		grep -v '^#' $OUT/$b-sw.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$b-sw.h
		echo "== decode order $b: hw frames $(wc -l < $OUT/$b-order.h), sw frames $(wc -l < $OUT/$b-sw.h)," \
			"distinct hw frames found among sw frames: $(sort -u $OUT/$b-order.h | grep -cxFf $OUT/$b-sw.h)," \
			"same position: $(paste -d' ' $OUT/$b-order.h $OUT/$b-sw.h | awk '$1==$2' | wc -l)," \
			"decode errors $(grep -c 'driver decode error' $OUT/order-$b.log)"
	done
}

encode_probe() {
	head -c $((640 * 480 * 3 / 2 * 30)) $MEDIA/testsrc2-1080p-30f.nv12 > $OUT/vga.nv12
	for fmt in H264 HEVC VP80; do
		reload >/dev/null
		E=$(node qcom-venus-encoder)
		dmesg -C
		echo 0x1f > /sys/class/video4linux/$(basename $E)/dev_debug
		capped 15 v4l2-ctl -d $E --set-fmt-video-out=width=640,height=480,pixelformat=NV12 \
			--set-fmt-video=width=640,height=480,pixelformat=$fmt --stream-mmap --stream-out-mmap \
			--stream-from=$OUT/vga.nv12 --stream-to=$OUT/vga.$fmt --stream-count=30 > $OUT/encprobe-$fmt.log 2>&1
		echo "== $fmt 640x480 on $E: exit $?, output $(stat -c %s $OUT/vga.$fmt 2>/dev/null) bytes"
		echo 0 > /sys/class/video4linux/$(basename $E)/dev_debug
		dmesg > $OUT/encprobe-$fmt-dmesg.log
		echo "   QBUF $(grep -c VIDIOC_QBUF $OUT/encprobe-$fmt-dmesg.log) DQBUF ok $(grep VIDIOC_DQBUF $OUT/encprobe-$fmt-dmesg.log | grep -vc error)" \
			"DQBUF err $(grep VIDIOC_DQBUF $OUT/encprobe-$fmt-dmesg.log | grep -c error)"
		grep -iE "venus|fail|error|timeout" $OUT/encprobe-$fmt-dmesg.log | grep -vE "VIDIOC_(DQBUF|G_SEL|ENUM|G_CTRL|G_STD|G_DV|SUBSCRIBE)" | head -5
	done
	ls /sys/kernel/debug/venus 2>/dev/null
	echo "== decoder still works after the encoder attempts?"
	verify h264-1080p-baseline.mp4
}

encode_camera_x264() {
	n=${1:-60}
	echo "== camera 490x652 NV12 -> libx264 ultrafast (1 thread), $n frames at 6 fps"
	capped 60 sh -c "$P/bin/tsvcam stream --fps 6 -n $n --nv12 -o - 2>$OUT/camx-half.log |
		$P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s 490x652 -r 6 -i pipe:0 \
		-threads 1 -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1M -y $OUT/cam-half-x264.mp4" 2>&1 | grep -E "bench:|rror" | tail -3
	tail -2 $OUT/camx-half.log
	echo "frames: $(frames $OUT/cam-half-x264.mp4); bytes $(stat -c %s $OUT/cam-half-x264.mp4)"
}

scaled() {	# WxH -> 30 frames of NV12 testsrc2 at that size
	[ -s $OUT/src-$1.nv12 ] || $P/bin/ffmpeg -v error -nostdin -f rawvideo -pix_fmt nv12 -s 1920x1080 \
		-i $MEDIA/testsrc2-1080p-30f.nv12 -vf scale=${1%x*}:${1#*x} -pix_fmt nv12 -f rawvideo -y $OUT/src-$1.nv12
	echo $OUT/src-$1.nv12
}

encode_sweep() {
	for wh in 640x480 480x640 1280x720 1920x1080 976x1296 490x652 496x656 1920x1088; do
		reload >/dev/null
		E=$(node qcom-venus-encoder)
		src=$(scaled $wh)
		dmesg -C
		echo 1 > /sys/module/venus_core/parameters/trace 2>/dev/null
		capped 15 v4l2-ctl -d $E --set-fmt-video-out=width=${wh%x*},height=${wh#*x},pixelformat=NV12 \
			--set-fmt-video=width=${wh%x*},height=${wh#*x},pixelformat=H264 --stream-mmap --stream-out-mmap \
			--stream-from=$src --stream-to=$OUT/sweep-$wh.h264 --stream-count=30 > $OUT/sweep-$wh.log 2>&1
		r=$?
		echo 0 > /sys/module/venus_core/parameters/trace 2>/dev/null
		dmesg > $OUT/sweep-$wh-dmesg.log
		echo "== v4l2-ctl H264 $wh: exit $r, $(stat -c %s $OUT/sweep-$wh.h264 2>/dev/null) bytes, frames [$(frames $OUT/sweep-$wh.h264)]," \
			"trace in $(grep -c 'enc done in' $OUT/sweep-$wh-dmesg.log) out $(grep -c 'enc done out' $OUT/sweep-$wh-dmesg.log)"
		grep -iE "venus.*(err|fail|timeout)|sys error|watchdog" $OUT/sweep-$wh-dmesg.log | head -3
	done
	for wh in 640x480 1280x720 480x640 496x656; do
		reload >/dev/null
		capped 60 $P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s $wh -r 30 \
			-stream_loop 9 -i $(scaled $wh) -c:v h264_v4l2m2m -b:v 2M -y $OUT/ffsweep-$wh.mp4 > $OUT/ffsweep-$wh.log 2>&1
		echo "== ffmpeg h264_v4l2m2m $wh, 300 frames: exit $?, frames [$(frames $OUT/ffsweep-$wh.mp4)];" \
			"$(tr '\r' '\n' < $OUT/ffsweep-$wh.log | grep bench: | tr '\n' ' ')"
	done
}

encode_camera_venus() {	# camera frames (tsvcam NV12) -> Venus H.264 at 490x652 and 980x1304, N frames at 6 fps
	n=${1:-60}
	for opt in "" "--full"; do
		[ -z "$opt" ] && { WH=490x652; tag=half; } || { WH=980x1304; tag=full; }
		reload >/dev/null
		echo "== camera $WH NV12 -> Venus H.264, $n frames at 6 fps"
		capped 60 sh -c "$P/bin/tsvcam stream --fps 6 -n $n --nv12 $opt -o - 2>$OUT/camv-$tag.log |
			$P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s $WH -r 6 -i pipe:0 \
			-c:v h264_v4l2m2m -b:v 1M -y $OUT/cam-$tag-venus.mp4" 2>&1 | grep -E "bench:|rror" | tail -3
		tail -2 $OUT/camv-$tag.log
		echo "frames: [$(frames $OUT/cam-$tag-venus.mp4)]; bytes $(stat -c %s $OUT/cam-$tag-venus.mp4 2>/dev/null)"
	done
}

traced() {
	name=$1 lvl=$2; shift 2
	reload >/dev/null
	echo $lvl > /sys/kernel/debug/venus/fw_level
	echo 1 > /sys/module/venus_core/parameters/trace
	dmesg -C
	dmesg -w > $OUT/$name.klog 2>&1 &
	dp=$!
	capped 60 "$@" > $OUT/$name.out 2>&1
	r=$?
	sleep 1
	echo 0 > /sys/module/venus_core/parameters/trace
	echo 0x18 > /sys/kernel/debug/venus/fw_level
	kill $dp 2>/dev/null
	echo "== $name: exit $r; klog $(wc -l < $OUT/$name.klog) lines, fw $(grep -c ' fw: ' $OUT/$name.klog)," \
		"MISS $(grep -c MISS $OUT/$name.klog), release events $(grep -c 'release event' $OUT/$name.klog)," \
		"park $(grep -c 'park idx' $OUT/$name.klog), resend $(grep -c 'resend idx' $OUT/$name.klog)"
	tr '\r' '\n' < $OUT/$name.out | grep -E "^frame=" | tail -1
}

encv() {	# WxH [FMT] [N]: one v4l2-ctl encode of the scaled testsrc, no reload, no cap
	wh=$1 fmt=${2:-H264} n=${3:-30}
	E=$(node qcom-venus-encoder); src=$(scaled $wh)
	timeout -k 3 15 v4l2-ctl -d $E --set-fmt-video-out=width=${wh%x*},height=${wh#*x},pixelformat=NV12 \
		--set-fmt-video=width=${wh%x*},height=${wh#*x},pixelformat=$fmt --stream-mmap --stream-out-mmap \
		--stream-from=$src --stream-to=$OUT/encv-$wh.$fmt --stream-count=$n
	echo "encv $wh $fmt: $(stat -c %s $OUT/encv-$wh.$fmt 2>/dev/null) bytes, [$(frames $OUT/encv-$wh.$fmt)]"
}

ffdec() {	# FILE NAME: hardware decode to framemd5, 25 s limit, then compare with software
	c=$(codec_of "$1")
	timeout -k 3 25 $P/bin/ffmpeg -hide_banner -nostdin -c:v ${c}_v4l2m2m -i $MEDIA/$1 -pix_fmt nv12 \
		-y -f framemd5 $OUT/$2.md5
	r=$?
	$P/bin/ffmpeg -hide_banner -nostdin -i $MEDIA/$1 -pix_fmt nv12 -y -f framemd5 $OUT/$2-sw.md5 >/dev/null 2>&1
	grep -v '^#' $OUT/$2.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$2.h
	grep -v '^#' $OUT/$2-sw.md5 | awk -F, '{print $6}' | tr -d ' ' > $OUT/$2-sw.h
	echo "ffdec $1: exit $r, hw $(wc -l < $OUT/$2.h) sw $(wc -l < $OUT/$2-sw.h)" \
		"same position $(paste -d' ' $OUT/$2.h $OUT/$2-sw.h | awk '$1==$2' | wc -l)"
}

ffenc() {	# WxH N: ffmpeg h264_v4l2m2m encode of the scaled testsrc
	wh=$1 n=${2:-60}
	timeout -k 3 20 $P/bin/ffmpeg -hide_banner -nostdin -loglevel verbose -f rawvideo -pix_fmt nv12 -s $wh -r 30 \
		-stream_loop 9 -i $(scaled $wh) -frames:v $n -c:v h264_v4l2m2m -b:v 2M -y $OUT/ffenc-$wh.mp4
	echo "ffenc $wh: exit $?, [$(frames $OUT/ffenc-$wh.mp4)]"
}

camenc() {	# [--full]: 60 camera frames (tsvcam NV12, 6 fps) to a file, then Venus H.264 via v4l2-ctl
	opt=${1:-}; [ -z "$opt" ] && WH=490x652 || WH=980x1304
	capped 30 $P/bin/tsvcam stream --fps 6 -n 60 --nv12 $opt -o - > $OUT/cam-$WH.nv12 2> $OUT/cam-$WH.log
	tail -2 $OUT/cam-$WH.log
	E=$(node qcom-venus-encoder)
	s=$(date +%s%N)
	capped 30 v4l2-ctl -d $E --set-fmt-video-out=width=${WH%x*},height=${WH#*x},pixelformat=NV12 \
		--set-fmt-video=width=${WH%x*},height=${WH#*x},pixelformat=H264 --stream-mmap --stream-out-mmap \
		--stream-from=$OUT/cam-$WH.nv12 --stream-to=$OUT/cam-$WH.h264 --stream-count=60 > /dev/null 2>&1
	echo "camenc $WH: exit $?, $((($(date +%s%N) - s) / 1000000)) ms, $(stat -c %s $OUT/cam-$WH.h264) bytes," \
		"[$(frames $OUT/cam-$WH.h264)]"
	rm -f $OUT/cam-$WH.nv12
}

ffencraw() {	# WxH N: ffmpeg h264_v4l2m2m encode of the scaled testsrc to raw Annex B
	wh=$1 n=${2:-60}
	timeout -k 3 20 $P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s $wh -r 30 \
		-stream_loop 9 -i $(scaled $wh) -frames:v $n -c:v h264_v4l2m2m -b:v 2M -y -f h264 $OUT/ffenc-$wh.h264 \
		> $OUT/ffencraw-$wh.log 2>&1
	echo "ffencraw $wh: exit $?, [$(frames $OUT/ffenc-$wh.h264)] $(grep -E 'bench: u' $OUT/ffencraw-$wh.log)"
}

bframes() {
	f=$1; c=$(codec_of "$f")
	reload
	D=$(node qcom-venus-decoder)
	dmesg -C 2>/dev/null || true
	echo 'module venus_core +p; module venus_dec +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
	echo 3 > /sys/class/video4linux/$(basename $D)/dev_debug
	[ -e /sys/kernel/debug/venus/fw_level ] && echo 0x3f > /sys/kernel/debug/venus/fw_level
	echo "== B-frame decode $(basename $f) on $D [$(frames $MEDIA/$f)]"
	capped 30 $P/bin/ffmpeg -hide_banner -nostdin -loglevel verbose -c:v ${c}_v4l2m2m \
		-i $MEDIA/$f -y -f framemd5 $OUT/bframes.framemd5 > $OUT/bframes-ffmpeg.log 2>&1
	echo "exit $? (124 = timeout); frames out: $(grep -cv '^#' $OUT/bframes.framemd5 2>/dev/null)"
	cp $OUT/bframes-ffmpeg.log $OUT/bframes-$(basename $f .mp4)-ffmpeg.log
	echo 0 > /sys/class/video4linux/$(basename $D)/dev_debug
	grep -E "v4l2|V4L2|Stream|frame=" $OUT/bframes-ffmpeg.log | tr '\r' '\n' | tail -25
	echo 'module venus_core -p; module venus_dec -p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
	dmesg > $OUT/bframes-dmesg.log
	cp $OUT/bframes-dmesg.log $OUT/bframes-$(basename $f .mp4)-dmesg.log
	echo "-- dmesg: $(wc -l < $OUT/bframes-dmesg.log) lines; ioctl summary:"
	grep -oE "VIDIOC_[A-Z_]+|venus[^:]*: [^,]*" $OUT/bframes-dmesg.log | sort | uniq -c | sort -rn | head -25
	echo "-- last 30 lines:"
	tail -30 $OUT/bframes-dmesg.log
}

encode_synth() {
	# 30 raw NV12 frames of testsrc2 looped ten times (no lavfi in this ffmpeg)
	src="-stream_loop 9 -f rawvideo -pix_fmt nv12 -s 1920x1080 -r 30 -i $MEDIA/testsrc2-1080p-30f.nv12"
	echo "== raw read only (baseline cost of the source)"
	capped 120 $P/bin/ffmpeg -hide_banner -nostdin -benchmark $src -frames:v 300 -f null - 2>&1 |
		grep -E "bench:" | tail -2
	echo "== Venus H.264 encode 1080p30, 300 frames, 8 Mb/s"
	capped 120 $P/bin/ffmpeg -hide_banner -nostdin -benchmark $src \
		-frames:v 300 -c:v h264_v4l2m2m -b:v 8M \
		-y $OUT/enc-venus-1080p.mp4 2>&1 | grep -E "bench:|Error|error|frame=" | tr '\r' '\n' | tail -3
	echo "frames: $(frames $OUT/enc-venus-1080p.mp4)"
	for p in ultrafast veryfast; do
		echo "== libx264 $p 1080p30, 300 frames"
		capped 300 $P/bin/ffmpeg -hide_banner -nostdin -benchmark $src \
			-frames:v 300 -threads 4 -c:v libx264 -preset $p -b:v 8M \
			-y $OUT/enc-x264-$p-1080p.mp4 2>&1 | grep -E "bench:|Error|error" | tail -2
		echo "frames: $(frames $OUT/enc-x264-$p-1080p.mp4)"
	done
}

encode_camera() {
	n=${1:-60}
	for size in half full; do
		[ $size = half ] && { WH=490x652; opt=""; } || { WH=980x1304; opt="--full"; }
		echo "== camera $WH NV12 -> Venus H.264, $n frames at 6 fps"
		capped 120 sh -c "$P/bin/tsvcam stream --fps 6 -n $n --nv12 $opt -o - 2>$OUT/cam-$size.log |
			$P/bin/ffmpeg -hide_banner -nostdin -benchmark -f rawvideo -pix_fmt nv12 -s $WH -r 6 -i pipe:0 \
			-c:v h264_v4l2m2m -b:v 1M -y $OUT/cam-$size-venus.mp4" 2>&1 | grep -E "bench:|Error|error" | tail -3
		tail -2 $OUT/cam-$size.log
		echo "frames: $(frames $OUT/cam-$size-venus.mp4); bytes $(stat -c %s $OUT/cam-$size-venus.mp4)"
	done
}

case "${1:-probe}" in
probe) probe ;;
decode) shift; decode hw "$@" ;;
verify) shift; verify "$@" ;;
encode-v4l2) encode_v4l2 ;;
reload) reload ;;
order) shift; order "$@" ;;
encode-probe) encode_probe ;;
encode-camera-x264) encode_camera_x264 "${2:-60}" ;;
encode-sweep) encode_sweep ;;
encode-camera-venus) encode_camera_venus "${2:-60}" ;;
traced) shift; traced "$@" ;;
scaled-path) scaled "$2" ;;
encv) shift; encv "$@" ;;
ffdec) shift; ffdec "$@" ;;
ffenc) shift; ffenc "$@" ;;
camenc) shift; camenc "$@" ;;
ffencraw) shift; ffencraw "$@" ;;
cpudecode) shift; decode sw "$@" ;;
bframes) bframes "$2" ;;
encode-synth) encode_synth ;;
encode-camera) encode_camera "${2:-60}" ;;
*) echo "usage: $0 probe|decode F..|cpudecode F..|bframes F|encode-synth|encode-camera [N]" >&2; exit 2 ;;
esac
