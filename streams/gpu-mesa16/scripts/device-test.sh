#!/usr/bin/env bash
# Run the gpu-mesa16 tests on the tablet against a Mesa installed by
# deploy-mesa.sh (default /opt/mesa-16bit), log to results/.
#
#   device-test.sh test [stock|16bit]          correctness tests (gles16 test)
#   device-test.sh gemm [stock|16bit] ['VARS' ['VARS']]  GEMM sweep; variants for the
#                                              128- and the 64-invocation tile
#   device-test.sh conv [stock|16bit] [L]      vocoder-shaped conv1d (512 ch, kernel 7)
#   device-test.sh raw stock|16bit 'CMD'       any command; "gles16 " runs the test binary
#
# Takes the device lock for each run (sessions stay short). GPU faults that
# happen during the run are listed at the end of the log.
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
what=${1:?usage: device-test.sh test|gemm|conv [stock|16bit]}; V=${2:-16bit}
LOG=$TOP/results/$what-$V-$(date +%Y%m%d-%H%M).log
T=/opt/mesa16-tests/build/gles16
case $what in
    test) cmd="$T test" ;;
    # Two tile shapes: 128 invocations x 8 rows (the FP32 optimum), and 64
    # invocations x 16 rows, where the FP16-storage/FP32-math variants fit
    # without spilling (see NOTES.md, "Register footprint").
    gemm) shift $(( $# < 2 ? $# : 2 ))
          v1=${1:-f32 m32 h32 h16}; v2=${2:-f32 h32 h16 hmix}
          cmd="for s in '512 512 512' '1024 1024 1024' '2048 2048 2048' '128 896 3584' '384 896 3584' '128 3584 896' '4000 4320 480'; do echo '## 128 invocations, RM 8'; $T gemm \$s $v1; echo '## 64 invocations, RM 16'; GLES16_RM=16 GLES16_LY=4 $T gemm \$s $v2; done" ;;
    conv) cmd="$T conv 512 ${3:-24000} 7 f32 m32 h16; GLES16_RM=16 GLES16_LY=4 $T conv 512 ${3:-24000} 7 f32 h32 h16 hmix" ;;
    raw) shift 2; cmd="$*"; cmd=${cmd//gles16 /$T } ;;
    *) echo "unknown: $what" >&2; exit 2 ;;
esac
R=$TOP/work/tmp/device-test-remote.sh
cat > "$R" <<EOF
. /opt/mesa-$V/env.sh; cd /tmp
t0=\$(cut -d' ' -f1 /proc/uptime)
echo "# \$(date) uptime \$t0 gpu \$(cat /sys/class/devfreq/*gpu*/cur_freq 2>/dev/null) mesa-$V \$(tr '\n' ';' < /opt/mesa-$V/PATCHES)"
$cmd 2>&1 | grep -v '^MESA: \|^pci id'
echo "# GPU faults during the run:"
dmesg | awk -v t=\$t0 '{ ts = substr(\$1, 2) + 0; if (ts > t) print }' | grep -iE 'gpu fault|hangcheck|lockup|offending' | tail -5
echo "# thermal (mC): \$(for z in /sys/class/thermal/thermal_zone*; do printf '%s=%s ' \$(cat \$z/type) \$(cat \$z/temp); done)"
EOF
"${A[@]}" push -q "$R" /tmp/gpu-mesa16-test.sh
"${A[@]}" shell "sh /tmp/gpu-mesa16-test.sh; rm -f /tmp/gpu-mesa16-test.sh" </dev/null | tee "$LOG"
echo "log: $LOG"
