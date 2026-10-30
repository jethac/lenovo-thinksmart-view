#!/usr/bin/env bash
# 60 s sustained GPU GEMM with thermal / frequency sampling, then GPU and CPU
# concurrency: CPU GEMM alone, GPU soak alone, both at once. Under the device lock.
# Output: results/soak-<date>.log
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
LOG=$TOP/results/soak-$(date +%Y%m%d-%H%M).log
KERN=${KERN:-st64r8k32}
"${A[@]}" push -q "$TOP/build/gles-sgemm" "$TOP/build/cpu-gemm" /tmp/gpu-root/
"${A[@]}" shell "KERN=$KERN sh -s" <<'DEV' | tee "$LOG"
. /tmp/gpu-root/env.sh; cd /tmp/gpu-root
sample() {  # one line: t, gpu MHz, gpu temp, cpu temps (C)
    t=$1; f=$(( $(cat /sys/class/devfreq/1c00000.gpu/cur_freq) / 1000000 ))
    line="t=$t gpu ${f}MHz"
    for z in /sys/class/thermal/thermal_zone*; do
        ty=$(cat $z/type); line="$line ${ty%-thermal}=$(( $(cat $z/temp) / 1000 ))"
    done
    echo "$line cpu0MHz=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 )) cpu4MHz=$(( $(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq) / 1000 ))"
}
echo "## idle"; sample 0
echo "## 60 s GPU soak: $KERN 1024^3"
./gles-sgemm soak 60 1024 1024 1024 $KERN 2>/dev/null > soak.out &
P=$!
i=0; while kill -0 $P 2>/dev/null; do sample $i; sleep 4; i=$((i+4)); done
cat soak.out
echo "## cool-down 20 s"; sleep 20; sample end
echo "## concurrency"
echo "# CPU alone"
./cpu-gemm 4 f32 1024 1024 1024; ./cpu-gemm 8 f32 1024 1024 1024; ./cpu-gemm 4 q8_0 1 1024 3072; ./cpu-gemm 8 q8_0 1 1024 3072
echo "# GPU alone (20 s)"
./gles-sgemm soak 20 1024 1024 1024 $KERN 2>&1 | grep -E "total|host CPU"
echo "# GPU soak + CPU at once"
( ./gles-sgemm soak 40 1024 1024 1024 $KERN 2>&1 | grep -E "soak t|total|host CPU" > both.out ) &
sleep 5
./cpu-gemm 4 f32 1024 1024 1024; ./cpu-gemm 8 f32 1024 1024 1024; ./cpu-gemm 4 q8_0 1 1024 3072; ./cpu-gemm 8 q8_0 1 1024 3072
sample conc
wait; cat both.out
echo "faults total: $(dmesg | grep -c 'gpu fault')"
DEV
echo "log: $LOG"
