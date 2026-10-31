#!/bin/bash
# Time the MagpieTTS text front end alone on the tablet (src/magpie-tokens.cpp):
# tokenizer construction, the first call per language (dictionary loading) and the
# median of 20 further calls, for the listening lines. Under the device lock; files
# in /dev/shm/tts-fe, removed afterwards.
#
#   device-frontend.sh OUTDIR
set -euo pipefail
OUT=$(realpath -m "$1"); mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
A=(adb -s "${TSV_ADB_SERIAL:-feb0bd1f028e4cb0}")
D=/dev/shm/tts-fe
if [[ ${TSV_DEVICE_LOCK_HELD:-} != 1 ]]; then
  export TSV_DEVICE_LOCK_HELD=1
  exec flock -w 3600 "$PROJ/.device.lock" "$0" "$@"
fi
"${A[@]}" shell "rm -rf $D; mkdir -p $D/tok $D/jdic $D/zh"
"${A[@]}" push -q "$HERE/work/magpie-tokens-a53" $D/magpie-tokens
"${A[@]}" push -q "$HERE"/downloads/models/magpie-tok/. $D/tok/
"${A[@]}" push -q "$HERE"/work/build-a53/open_jtalk_dic/. $D/jdic/
"${A[@]}" push -q "$HERE"/downloads/NeMo-Speech.cpp/src/tts/tokenizer/mandarin_data/. $D/zh/
trap '"${A[@]}" shell "rm -rf $D" </dev/null || true' EXIT
for l in en ja zh; do
  grep "^$l-" "$HERE/cases/lines.tsv" | cut -d'|' -f3 > "$OUT/lines-$l.txt"
  "${A[@]}" push -q "$OUT/lines-$l.txt" $D/
  "${A[@]}" shell "cd $D && chmod +x magpie-tokens && MAGPIE_OPENJTALK_DIC_DIR=$D/jdic MAGPIE_MANDARIN_G2P_DIR=$D/zh ./magpie-tokens tok $l lines-$l.txt 20" \
    > "$OUT/tokens-$l.txt" 2> "$OUT/timing-$l.txt" </dev/null
  echo "$l: $(paste -sd' ' "$OUT/timing-$l.txt")"
done
