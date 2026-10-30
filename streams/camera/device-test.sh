#!/bin/sh
# Run on the device (root) with the camera stream kernel booted.
# Probes the sensor (module load), shows the media graph, and, only if the
# lens cover reads open, captures raw frames from CAMSS.
#
#   device-test.sh probe           load modules, print sensor probe log
#   device-test.sh capture [MODE]  configure the pipeline and grab frames
#                                  MODE: WxH (default 2608x1960)
#   device-test.sh pattern [MODE]  same, with the sensor's colour bar test
#                                  pattern on (no scene content, so it runs
#                                  whatever the lens cover reads)
#   device-test.sh cover           print the lens cover switch state
set -u
OUT=/var/tmp/camtest
mkdir -p $OUT

lens_cover_closed() {
	ev=$(for e in /sys/class/input/event*; do
		[ "$(cat $e/device/name)" = gpio-keys ] && echo /dev/input/$(basename $e)
	done | head -1)
	[ -n "$ev" ] || { echo "no gpio-keys input device" >&2; return 0; }
	# evtest --query exits 10 when the switch is set (cover closed)
	evtest --query "$ev" EV_SW SW_CAMERA_LENS_COVER
	[ $? -eq 10 ]
}

probe() {
	modprobe i2c-qcom-cci
	modprobe qcom-camss
	modprobe s5kc505a
	sleep 2
	dmesg | grep -iE "s5kc505a|camss|cci|csiphy|csid" | tail -40
	ls /dev/media* /dev/v4l-subdev* /dev/video* 2>/dev/null
}

entity() {	# name prefix -> exact entity name (may contain spaces, e.g. "s5kc505a 3-0037")
	media-ctl -d "$MDEV" -p | sed -n "s/^- entity [0-9]*: \($1.*\) ([0-9]* pads\{0,1\},.*/\1/p" | head -1
}

capture() {
	PATTERN=$1; shift
	MODE=${1:-2608x1960}
	W=${MODE%x*} H=${MODE#*x}
	if [ "$PATTERN" = 0 ] && lens_cover_closed; then
		echo "lens cover is closed: not streaming" >&2
		exit 3
	fi
	MDEV=$(for m in /dev/media*; do
		media-ctl -d $m -p 2>/dev/null | grep -q qcom-camss && echo $m
	done | head -1)
	[ -n "$MDEV" ] || { echo "no CAMSS media device" >&2; exit 1; }
	SENSOR=$(entity s5kc505a)
	echo "media $MDEV, sensor '$SENSOR', mode ${W}x${H}"
	FMT="SGRBG10_1X10/${W}x${H} field:none"
	media-ctl -d $MDEV -r
	media-ctl -d $MDEV -l "\"$SENSOR\":0->\"msm_csiphy0\":0[1]"
	media-ctl -d $MDEV -l '"msm_csiphy0":1->"msm_csid0":0[1]'
	media-ctl -d $MDEV -l '"msm_csid0":1->"msm_ispif0":0[1]'
	media-ctl -d $MDEV -l '"msm_ispif0":1->"msm_vfe0_rdi0":0[1]'
	media-ctl -d $MDEV -V "\"$SENSOR\":0[fmt:$FMT]"
	media-ctl -d $MDEV -V "\"msm_csiphy0\":0[fmt:$FMT]"
	media-ctl -d $MDEV -V "\"msm_csid0\":0[fmt:$FMT]"
	media-ctl -d $MDEV -V "\"msm_ispif0\":0[fmt:$FMT]"
	media-ctl -d $MDEV -V "\"msm_vfe0_rdi0\":0[fmt:$FMT]"
	media-ctl -d $MDEV -p > $OUT/topology.txt
	SDEV=$(media-ctl -d $MDEV -e "$SENSOR")
	v4l2-ctl -d $SDEV --set-ctrl test_pattern=$PATTERN
	# EXPOSURE (lines) and GAIN (analogue code, 32 = 1x) from the environment
	[ -n "${EXPOSURE:-}" ] && v4l2-ctl -d $SDEV --set-ctrl exposure=$EXPOSURE
	[ -n "${GAIN:-}" ] && v4l2-ctl -d $SDEV --set-ctrl analogue_gain=$GAIN
	v4l2-ctl -d $SDEV --get-ctrl exposure,analogue_gain,vertical_blanking,test_pattern
	[ "$PATTERN" = 0 ] && TAG=scene || TAG=pattern$PATTERN
	VDEV=$(media-ctl -d $MDEV -e msm_vfe0_video0)
	echo "capture node $VDEV, sensor subdev $SDEV, $TAG"
	timeout 20 v4l2-ctl -d $VDEV --set-fmt-video=width=$W,height=$H,pixelformat=pgAA \
		--stream-mmap --stream-count=4 --stream-skip=4 \
		--stream-to=$OUT/frame-${W}x${H}-$TAG.raw 2>&1 | tail -5
	# frame rate over 40 frames, not saved
	timeout 20 v4l2-ctl -d $VDEV --stream-mmap --stream-count=40 2>&1 | tr '<' '\n' | grep -i fps | tail -2
	v4l2-ctl -d $SDEV --set-ctrl test_pattern=0
	dmesg | tail -20
	ls -la $OUT
}

case "${1:-probe}" in
probe) probe ;;
capture) shift; capture 0 "$@" ;;
pattern) shift; capture 2 "$@" ;;
cover) if lens_cover_closed; then echo closed; else echo open; fi ;;
*) echo "usage: $0 probe|capture [WxH]|pattern [WxH]|cover" >&2; exit 2 ;;
esac
