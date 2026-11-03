#!/bin/sh
# On the PGX: export one narrow-student snapshot and render the evaluation
# lines through ONNX Runtime (CPU), then UTMOS of the renders.
#   eval-narrow.sh LANG WIDTH STEP [TAG]     -> ~/straylight-tts/eval/narrow-LANG-WIDTH-STEP/
set -eu
L=$1 W=$2 S=$3 T=${4:-}
cd "$HOME/straylight-tts"
V=$(case $L in en) echo af_heart;; ja) echo "jf_alpha*0.7+af_heart*0.3";; zh) echo "zf_xiaoni*0.7+af_heart*0.3";; esac)
N=narrow-$L-$W$T-$(printf %07d "$S")
./dk.sh "ev-$N" sh -c "cd /w/paradee/$L && export PYTHONPATH=/w/src/kokoro_pkg PARADEE_VOICE='$V' CUDA_VISIBLE_DEVICES= && \
  python scripts/export_narrow.py $W checkpoints/narrow_$W$T/step-$(printf %07d "$S").pt /w/export/$N > /w/export/$N.log 2>&1 && \
  python /w/src/synth-paradee.py /w/export/$N/model.onnx /w/downloads/hexgrad/config.json /w/data/eval-$L.phon.tsv /w/eval/$N --threads 4 && \
  TORCH_HOME=/w/downloads/torch-hub python /w/src/utmos.py /w/eval/$N" 2>&1 | grep -E "^total|^/w/eval|Error|Traceback"
