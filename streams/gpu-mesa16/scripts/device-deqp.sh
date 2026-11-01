#!/usr/bin/env bash
# Run dEQP-GLES31 test groups on the tablet against /opt/mesa-<variant>, with
# the deqp-gles31 built by build-deqp.sh, and summarise pass/fail per group.
#
#   device-deqp.sh push                       install deqp-gles31 + data under /opt/mesa16-deqp
#   device-deqp.sh run 16bit|stock PATTERN..  e.g. 'dEQP-GLES31.functional.ssbo.*'
#
# Each pattern runs in its own locked session. Logs: results/deqp-<variant>-<n>.log
# (one line per case: name and status), plus a summary.
set -euo pipefail
LOCK=/home/jethac/Projects/lenovo-8/.device.lock
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
A=(adb -s feb0bd1f028e4cb0)
D=/opt/mesa16-deqp
B=$TOP/work/build-deqp/modules/gles31
case ${1:-} in
push)
    flock -w 3600 "$LOCK" sh -c "tar -C '$B' -cf - deqp-gles31 gles31 | ${A[*]} shell 'rm -rf $D && mkdir -p $D && tar -C $D -xf - && du -sh $D'"
    ;;
run)
    V=$2; shift 2
    for pat in "$@"; do
        n=$(echo "$pat" | sed 's/^dEQP-GLES31\.//; s/\.\*$//; s/[^A-Za-z0-9_.]/_/g')
        LOG=$TOP/results/deqp-$V-$n.log
        flock -w 3600 "$LOCK" "${A[@]}" shell ". /opt/mesa-$V/env.sh; cd $D; t0=\$(cut -d' ' -f1 /proc/uptime);
            echo \"# \$(date) mesa-$V \$(tr '\n' ';' < /opt/mesa-$V/PATCHES) pattern $pat\";
            ./deqp-gles31 --deqp-case='$pat' --deqp-surface-type=pbuffer --deqp-gl-config-name=rgba8888d24s8ms0 \
                --deqp-surface-width=256 --deqp-surface-height=256 --deqp-log-images=disable \
                --deqp-log-shader-sources=disable --deqp-log-filename=/tmp/deqp.qpa --deqp-watchdog=enable 2>&1 |
              awk '/^Test case /{c=\$3} /^  (Pass|Fail|NotSupported|QualityWarning|CompatibilityWarning|InternalError|Crash|Timeout|ResourceError) /{print c, \$1}' ;
            rm -f /tmp/deqp.qpa;
            echo '# GPU faults during the run:';
            dmesg | awk -v t=\$t0 '{ ts = substr(\$1, 2) + 0; if (ts > t) print }' | grep -iE 'gpu fault|hangcheck|lockup' | tail -3" </dev/null > "$LOG"
        echo "$V $pat: $(grep "^'dEQP" "$LOG" | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')  ($LOG)"
    done
    ;;
*) echo "usage: $0 push | run 16bit|stock PATTERN..." >&2; exit 2 ;;
esac
