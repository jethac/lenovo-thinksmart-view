#!/bin/bash
# Can MagpieTTS and Qwen3-ASR be resident together on the tablet's 2 GB? Under the
# device lock. Models live on the root filesystem (eMMC) and are memory-mapped
# or read from there, as deployed; /var/tmp/ttsmem is removed afterwards.
#
#   device-memory.sh OUTDIR
#
# Runs: ASR alone, TTS alone, then both at once (the ASR transcribing 15 Japanese
# clips in a loop while the TTS speaks a 3-sentence Japanese reply). Samples every
# 0.2 s: MemAvailable, page cache, each process's RssAnon/RssFile and major faults.
# Page cache is dropped before each run so every run starts cold. Everything runs in
# one systemd scope limited to MEMMAX (default 1550M of the 1.9 GiB, leaving the
# system services their share), so if the pair does not fit only they are killed.
set -euo pipefail
OUT=$(realpath -m "$1"); mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
ASR=$PROJ/streams/asr
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
M=$HERE/downloads/models
D=/var/tmp/ttsmem
BIN=${BIN:-$HERE/work/build-a53/bin/nemo-speech}
ASRMODEL=${ASRMODEL:-$ASR/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf}
TTSENV=${TTSENV:-}
TTSARGS=${TTSARGS:---tts.threads 8}
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi
"${A[@]}" shell "rm -rf $D; mkdir -p $D/tok $D/jdic $D/zh $D/clips"
"${A[@]}" push -q "$BIN" $D/nemo-speech
"${A[@]}" push -q "$M/magpie_tts_multilingual_357m.v2607.q8_0.gguf" $D/magpie.gguf
"${A[@]}" push -q "$M/nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf" $D/codec.gguf
"${A[@]}" push -q "$M"/magpie-tok/. $D/tok/
"${A[@]}" push -q "$HERE"/work/build-a53/open_jtalk_dic/. $D/jdic/
"${A[@]}" push -q "$HERE"/downloads/NeMo-Speech.cpp/src/tts/tokenizer/mandarin_data/. $D/zh/
"${A[@]}" push -q "$ASR/work/build-a53/bin/transcribe-cli" "$ASRMODEL" $D/
"${A[@]}" push -q "$ASR"/work/testset/cmd-ja/. $D/clips/
trap '"${A[@]}" shell "rm -rf $D" </dev/null || true' EXIT
TEXT=$(grep '^ja-3|' "$HERE/cases/lines.tsv" | cut -d'|' -f3)
printf '%s' "$TEXT" > "$OUT/text.txt"; "${A[@]}" push -q "$OUT/text.txt" $D/text.txt
cat > "$OUT/.mem.sh" <<RUN
cd $D; chmod +x nemo-speech transcribe-cli; ls clips/*.wav > clips.list
AM=\$(basename $ASRMODEL)
asr() { ./transcribe-cli -q -m \$AM -l ja --threads 8 --batch clips.list --batch-jsonl > asr-\$1.jsonl 2> asr-\$1.err; }
tts() { env MAGPIE_OPENJTALK_DIC_DIR=$D/jdic MAGPIE_MANDARIN_G2P_DIR=$D/zh $TTSENV ./nemo-speech synthesize -i text.txt \\
  --magpie-model magpie.gguf --codec-model codec.gguf --tokenizer-dir tok --language ja --speaker 4 --seed 1 \\
  --device cpu --verbose $TTSARGS -o tts-\$1.wav --force > tts-\$1.err 2>&1; }
pstat() { # pid -> anon_kB file_kB hwm_kB majflt
  [ -r /proc/\$1/status ] || { echo "- - - -"; return; }
  a=\$(awk '/RssAnon/{print \$2}' /proc/\$1/status); f=\$(awk '/RssFile/{print \$2}' /proc/\$1/status)
  h=\$(awk '/VmHWM/{print \$2}' /proc/\$1/status); m=\$(awk '{print \$12}' /proc/\$1/stat 2>/dev/null)
  echo "\$a \$f \$h \$m"; }
sample() { # name pidA pidT
  echo "t_ms memavail_kB cached_kB asr_anon asr_file asr_hwm asr_majflt tts_anon tts_file tts_hwm tts_majflt" > mem-\$1.tsv
  t0=\$(date +%s%N)
  alive() { [ "\$1" != 0 ] && kill -0 \$1 2>/dev/null; }
  while alive \$2 || alive \$3; do
    echo "\$(( (\$(date +%s%N)-t0)/1000000 )) \$(awk '/MemAvailable/{print \$2}' /proc/meminfo) \$(awk '/^Cached/{print \$2}' /proc/meminfo) \$(pstat \$2) \$(pstat \$3)" >> mem-\$1.tsv
    sleep 0.2
  done; }
run() { # name what
  sync; echo 3 > /proc/sys/vm/drop_caches; free -m > free-\$1.txt
  pa=0; pt=0; t0=\$(date +%s%N)
  case \$2 in *asr*) ( asr \$1; echo \$(( (\$(date +%s%N)-t0)/1000000 )) > asr-\$1.ms ) & pa=\$!;; esac
  case \$2 in *tts*) ( tts \$1; echo \$(( (\$(date +%s%N)-t0)/1000000 )) > tts-\$1.ms ) & pt=\$!;; esac
  sleep 0.1; pa2=\$(pgrep -f "transcribe-cli -q" | head -1); pt2=\$(pgrep -f "nemo-speech synthesize" | head -1)
  sample \$1 \${pa2:-0} \${pt2:-0}; wait
  dmesg | tail -20 | grep -i -E "oom|killed" > oom-\$1.txt || true; }
run asr asr; run tts tts; run both asr+tts
echo done > mem.done
RUN
"${A[@]}" push -q "$OUT/.mem.sh" $D/mem.sh
"${A[@]}" shell "setsid nohup systemd-run --scope -q -p MemoryMax=${MEMMAX:-1550M} -p MemorySwapMax=0 sh $D/mem.sh > $D/mem.log 2>&1 < /dev/null &"
until timeout 20 "${A[@]}" shell "test -e $D/mem.done" </dev/null 2>/dev/null; do sleep 5; done
"${A[@]}" shell "cd $D && tar cf - *.tsv *.txt *.ms *.err *.jsonl mem.log" </dev/null | tar xf - -C "$OUT"
echo "memory run in $OUT"
