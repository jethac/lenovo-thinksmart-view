#!/bin/bash
# A voice directory for the tablet: every MODEL.onnx gets MODEL.ort in the
# runtime's version (ONNX Runtime 1.28, as listen/tts/stage.sh writes them),
# and with --ort-only the .onnx files are dropped (the listener's default
# memory setting maps the .ort files; this halves the disk cost).
#   pack-voice.sh DIR [--ort-only]
set -euo pipefail
ORT_PYTHON=${ORT_PYTHON:-/run/media/jethac/Shared/lenovo-8-offload/streams/tts/downloads/ort128-venv/bin/python}
dir=$1
for m in "$dir"/*.onnx; do
  d=$(mktemp -d)
  cp "$m" "$d/m.onnx"
  "$ORT_PYTHON" -I -m onnxruntime.tools.convert_onnx_models_to_ort "$d/m.onnx" --optimization_style Runtime > "$d/log" 2>&1 || { cat "$d/log" >&2; exit 1; }
  mv "$d/m.with_runtime_opt.ort" "${m%.onnx}.ort"
  rm -rf "$d"
  [[ ${2:-} == --ort-only ]] && rm "$m"
done
du -sh "$dir"; ls -la "$dir"
