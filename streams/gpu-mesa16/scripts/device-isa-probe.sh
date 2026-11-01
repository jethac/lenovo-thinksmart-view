#!/usr/bin/env bash
# Step 1 of the stream: do a5xx ldgb/stgb really do 16-bit SSBO loads and
# stores? Runs probes/u32.comp (a 32-bit SSBO copy) under stock Mesa, then
# replaces its ir3 binary with each hand-written probes/asm/P*.asm through
# IR3_SHADER_OVERRIDE_PATH (the override is keyed by the variant's blake3,
# which is read from the first run) and dumps the output buffer.
#
#   device-isa-probe.sh [MESA_VARIANT]      default: stock (/opt/mesa-stock)
#
# Log: results/isa-probe-<date>.log. Takes the device lock.
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 1800 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
V=${1:-stock}
LOG=$TOP/results/isa-probe-$(date +%Y%m%d-%H%M).log
tar -C "$TOP" -cf - probes build/ssbo-probe | "${A[@]}" shell 'rm -rf /tmp/isa-probe && mkdir -p /tmp/isa-probe && tar -C /tmp/isa-probe -xf -'
"${A[@]}" shell "cd /tmp/isa-probe; . /opt/mesa-$V/env.sh; export MESA_SHADER_CACHE_DISABLE=true
echo '== baseline (compiler output), u32.comp'
IR3_SHADER_DEBUG=disasm ./build/ssbo-probe probes/u32.comp > base.log 2>&1
sed 's/^MESA: info: //' base.log | awk '/Native code for unnamed CL/{f=1} f&&/^end/{f=0} f'
grep -v '^MESA' base.log
B=\$(sed -n 's/.*Native code for unnamed CL shader .* with blake3 \\([0-9a-f]*\\):.*/\\1/p' base.log | head -1)
echo \"blake3 \$B\"
for f in probes/asm/P*.asm; do
  n=\$(basename \$f .asm); mkdir -p ov/\$n; cp \$f ov/\$n/\$B.asm
  echo; echo \"== \$n\"; grep -E 'ldgb|stgb' \$f
  IR3_SHADER_OVERRIDE_PATH=\$PWD/ov/\$n IR3_SHADER_DEBUG=disasm ./build/ssbo-probe probes/u32.comp > run.log 2>&1
  grep -q '(overridden)' run.log || echo 'NOT OVERRIDDEN'
  grep -v '^MESA' run.log
done
dmesg | grep -iE 'fault|hangcheck|lockup|recover' | tail -5; echo \"uptime \$(cut -d. -f1 /proc/uptime) s\"
rm -rf /tmp/isa-probe" </dev/null | tee "$LOG"
echo "log: $LOG"
