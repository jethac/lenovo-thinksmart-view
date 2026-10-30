#!/usr/bin/env bash
# GPU (gles-sgemm) and CPU (cpu-gemm, ggml) GEMM sweep on the tablet, under the
# device lock. Needs the Mesa tmpfs install (install-mesa-tmpfs.sh mesa) and
# scripts/build.sh. Output: results/sweep-<date>.log
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 3600 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
LOG=$TOP/results/sweep-$(date +%Y%m%d-%H%M).log
"${A[@]}" push -q "$TOP/build/gles-sgemm" "$TOP/build/cpu-gemm" /tmp/gpu-root/
# M K N  label
SHAPES=(
  "512 512 512 square"
  "1024 1024 1024 square"
  "2048 2048 2048 square"
  "64 896 896 attn-proj-5s"
  "128 896 896 attn-proj-10s"
  "384 896 896 attn-proj-30s"
  "128 896 3584 ffn-fc1-10s"
  "128 3584 896 ffn-fc2-10s"
  "384 896 3584 ffn-fc1-30s"
  "64 7680 896 conv_out-5s"
  "4000 4320 480 conv1-im2col-5s"
  "1040 4320 480 conv2-im2col-5s"
)
GPU_K="r8x4_8x8 st64x32 st64r8k32 st64r8k32t8 st64r8k32t16 r4x4_8x8 r4x4_8x8h"
"${A[@]}" shell "cat /proc/sys/kernel/random/boot_id; uptime; cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | sort | uniq -c" </dev/null | tee "$LOG"
for s in "${SHAPES[@]}"; do
    read -r M K N L <<<"$s"
    extra=""
    (( M * K * N <= 1024 * 1024 * 1024 )) && extra="naive16 tile16"
    echo "### $L M=$M K=$K N=$N" | tee -a "$LOG"
    "${A[@]}" shell ". /tmp/gpu-root/env.sh; cd /tmp/gpu-root; ./gles-sgemm bench $M $K $N $extra $GPU_K 2>/dev/null" </dev/null | tee -a "$LOG"
    for t in f32 q8_0; do
        "${A[@]}" shell "cd /tmp/gpu-root; ./cpu-gemm 8 $t $M $K $N; ./cpu-gemm 4 $t $M $K $N" </dev/null | tee -a "$LOG"
    done
done
"${A[@]}" shell 'dmesg | grep -c "gpu fault"; for z in /sys/class/thermal/thermal_zone*; do echo $(cat $z/type) $(cat $z/temp); done' </dev/null | tee -a "$LOG"
echo "log: $LOG"
