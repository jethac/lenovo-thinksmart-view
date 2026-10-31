#!/bin/bash
# Run MagpieTTS (NeMo-Speech.cpp, static aarch64) on the tablet under the device
# lock. Binary, models and front-end data go to /dev/shm/tts (RAM) and are
# removed afterwards.
#
#   device-tts.sh CASES OUTDIR
#
# CASES: one case per line, "tag|lang|threads|speaker|env|extra args|text"
# (env: VAR=value assignments for the run, may be empty).
# Per case OUTDIR gets tag.wav, tag.err (log with the runtime's timing line),
# tag.peak_kb (VmHWM), tag.wall_ms, plus CPU temperature and frequency.
# Environment: BIN (nemo-speech binary), MAGPIE, CODEC (GGUFs), KEEP=1 to leave
# the payload in /dev/shm for a following run, MEMMAX (default 1300M): each run is
# a systemd scope with that memory limit, so running out of memory kills only the run.
set -euo pipefail
CASES=$(realpath "$1"); OUT=$(realpath -m "$2"); mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
SERIAL=${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}
A=(adb -s "$SERIAL")
M=$HERE/downloads/models
BIN=${BIN:-$HERE/work/build-a53/bin/nemo-speech}
MAGPIE=${MAGPIE:-$M/magpie_tts_multilingual_357m.v2607.q8_0.gguf}
CODEC=${CODEC:-$M/nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf}
D=/dev/shm/tts

if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi

push_if_changed() {  # local remote
  local l=$1 r=$2 ls rs
  ls=$(stat -c %s "$l"); rs=$("${A[@]}" shell "stat -c %s $r 2>/dev/null || echo -")
  [[ $ls == "$rs" ]] || "${A[@]}" push -q "$l" "$r"
}
"${A[@]}" shell "mkdir -p $D/bin $D/models $D/tok $D/jdic $D/zh"
push_if_changed "$BIN" $D/bin/nemo-speech
push_if_changed "$MAGPIE" $D/models/magpie.gguf
push_if_changed "$CODEC" $D/models/codec.gguf
for f in "$M"/magpie-tok/*; do push_if_changed "$f" $D/tok/$(basename "$f"); done
for f in "$HERE"/work/build-a53/open_jtalk_dic/*; do push_if_changed "$f" $D/jdic/$(basename "$f"); done
for f in "$HERE"/downloads/NeMo-Speech.cpp/src/tts/tokenizer/mandarin_data/*; do push_if_changed "$f" $D/zh/$(basename "$f"); done
"${A[@]}" shell "chmod +x $D/bin/nemo-speech"
[[ ${KEEP:-0} == 1 ]] || trap '"${A[@]}" shell "rm -rf $D" || true' EXIT

while IFS='|' read -r tag lang thr spk envs extra text; do
  [[ -z $tag || $tag == \#* ]] && continue
  printf '%s' "$text" > "$OUT/$tag.txt"
  "${A[@]}" push -q "$OUT/$tag.txt" $D/in.txt
  # The case runs detached on the device (it survives an adbd restart); poll for rc.
  cat > "$OUT/.run.sh" <<RUN
cd $D && rm -f out.wav rc
cat /sys/devices/system/cpu/cpu[04]/cpufreq/scaling_cur_freq | paste -sd' ' > freq0
for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep cpu | head -4 | paste -sd' ' > temp0
t0=\$(date +%s%N)
systemd-run --scope -q -p MemoryMax=${MEMMAX:-1300M} -p MemorySwapMax=0 env MAGPIE_OPENJTALK_DIC_DIR=$D/jdic MAGPIE_MANDARIN_G2P_DIR=$D/zh $envs ./bin/nemo-speech synthesize -i in.txt \\
  --magpie-model models/magpie.gguf --codec-model models/codec.gguf --tokenizer-dir tok \\
  --language $lang --speaker $spk --seed 1 --device cpu --tts.threads $thr --verbose $extra -o out.wav --force > err 2>&1 &
p=\$!; peak=0
while kill -0 \$p 2>/dev/null; do v=\$(awk '/VmHWM/{print \$2}' /proc/\$p/status 2>/dev/null); [ -n "\$v" ] && [ "\$v" -gt \$peak ] && peak=\$v; sleep 0.1; done
wait \$p; r=\$?; echo \$peak > peak_kb; echo \$(( (\$(date +%s%N) - t0) / 1000000 )) > wall_ms
for z in /sys/class/thermal/thermal_zone*; do echo \$(cat \$z/type) \$(cat \$z/temp); done | grep cpu | head -4 | paste -sd' ' > temp1
echo \$r > rc
RUN
  "${A[@]}" push -q "$OUT/.run.sh" $D/run.sh </dev/null
  "${A[@]}" shell "rm -f $D/rc; setsid nohup sh $D/run.sh > /dev/null 2>&1 < /dev/null &" </dev/null
  until timeout 20 "${A[@]}" shell "test -s $D/rc" </dev/null 2>/dev/null; do sleep 3; done
  for s in err rc peak_kb wall_ms freq0 temp0 temp1; do "${A[@]}" pull -q $D/$s "$OUT/$tag.$s" </dev/null; done
  "${A[@]}" pull -q $D/out.wav "$OUT/$tag.wav" </dev/null 2>/dev/null || true
  echo "$tag: rc=$(cat "$OUT/$tag.rc") peak=$(( $(cat "$OUT/$tag.peak_kb") / 1024 )) MiB wall=$(cat "$OUT/$tag.wall_ms") ms"
  grep -o 'e2e_audio_s=[^ ]*\|e2e_rtf=[^ ]*\|e2e_ttfa_ms=[^ ]*' "$OUT/$tag.err" | paste -sd' ' || true
done < "$CASES"
