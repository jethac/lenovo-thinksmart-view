#!/bin/bash
# Synthesise the listening lines (cases/lines.tsv) for every built-in speaker with
# the laptop build of NeMo-Speech.cpp and the same Q8_0 GGUF the device runs.
#
#   laptop-samples.sh [OUTDIR] [SPEAKERS]     default work/samples, "0 1 2 3 4"
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$S/work/samples}; SPK=${2:-"0 1 2 3 4"}; mkdir -p "$OUT"
M=$S/downloads/models; B=$S/work/build-native
NAMES=(aria jason john leo sofia)
export MAGPIE_OPENJTALK_DIC_DIR=$B/open_jtalk_dic
export MAGPIE_MANDARIN_G2P_DIR=$S/downloads/NeMo-Speech.cpp/src/tts/tokenizer/mandarin_data
for spk in $SPK; do
  grep -v '^#' "$S/cases/lines.tsv" | while IFS='|' read -r id lang text; do
    f=$OUT/${NAMES[$spk]}-$id.wav
    [[ -s $f ]] && continue
    "$B/bin/nemo-speech" synthesize "$text" --magpie-model "$M/magpie_tts_multilingual_357m.v2607.q8_0.gguf" \
      --codec-model "$M/nemo_nano_codec_22khz_1.89kbps_21.5fps.decoder.f16.gguf" --tokenizer-dir "$M/magpie-tok" \
      --language "$lang" --speaker "$spk" --seed 1 --device cpu --tts.threads 6 --tts.chunk-frames 1000 \
      -o "$f" --force > "$f.log" 2>&1 </dev/null
    echo "$(basename "$f") $(grep -o 'e2e_audio_s=[^ ]*' "$f.log" | tail -1)"
  done
done
