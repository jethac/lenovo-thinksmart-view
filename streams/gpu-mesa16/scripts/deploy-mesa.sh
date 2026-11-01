#!/usr/bin/env bash
# Install a staged Mesa build (build-mesa.sh) on the tablet under /opt, plus the
# test programs and probe shaders under /opt/mesa16-tests. Nothing outside /opt
# is touched; the system has no Mesa of its own and the UI renders in software.
#
#   deploy-mesa.sh [16bit|stock]...      default: 16bit
#   deploy-mesa.sh --remove              rm -rf /opt/mesa-16bit /opt/mesa-stock /opt/mesa16-tests /opt/mesa16-deqp
#
# Takes the device lock.
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
[[ -n ${TSV_LOCKED:-} ]] || exec env TSV_LOCKED=1 flock -w 1800 "$LOCK" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
if [[ ${1:-} == --remove ]]; then
    "${A[@]}" shell 'rm -rf /opt/mesa-16bit /opt/mesa-stock /opt/mesa16-tests /opt/mesa16-deqp /tmp/mesa-shader-cache-*' </dev/null
    exit 0
fi
(( $# )) || set -- 16bit
for v in "$@"; do
    S=$TOP/work/stage-$v
    [[ -d $S/opt/mesa-$v ]] || { echo "not staged: $S" >&2; exit 1; }
    tar -C "$S" -cf - opt/mesa-$v | "${A[@]}" shell "rm -rf /opt/mesa-$v /tmp/mesa-shader-cache-$v && tar -C / -xf - && cat /opt/mesa-$v/PATCHES | head -20; du -sh /opt/mesa-$v"
done
tar -C "$TOP" -cf - build/ssbo-probe build/gles16 probes 2>/dev/null |
    "${A[@]}" shell "rm -rf /opt/mesa16-tests && mkdir -p /opt/mesa16-tests && tar -C /opt/mesa16-tests -xf - && ls /opt/mesa16-tests/*"
