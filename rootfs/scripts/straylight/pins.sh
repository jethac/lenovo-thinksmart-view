# Sourced by build-straylight.sh: what the image's Straylight voice assistant is
# built from. Changing a commit here means rebuilding and re-pinning
# straylight/SHA256SUMS (build-straylight.sh --repin prints the new sums).

# The app (screen, listener, ai& client, Wi-Fi picker) and its hardware crate,
# a path dependency at ../thinksmart-view-hal. The Slint fork and transcribe.cpp
# are pinned by straylight-voice itself (Slint as a git dependency at a revision
# in its Cargo.toml and Cargo.lock; transcribe.cpp by listen/asr/build.sh).
STRAYLIGHT_REPO=git@github.com:jethac/straylight-voice.git
STRAYLIGHT_COMMIT=b8f4a2636e61f1f45cdbc1206879623697aa339f
VIEW_HAL_REPO=git@github.com:jethac/thinksmart-view-hal.git
VIEW_HAL_COMMIT=560905784220d76aeceab31da7a01bdb14f713ab
SLINT_REPO=git@github.com:jethac/slint.git
TRANSCRIBE_REPO=git@github.com:handy-computer/transcribe.cpp.git

# Python for straylight-voice's scripts: make-fonts.sh (fontTools),
# listen/scripts/export-frontend.py (onnx) and requant-conv.py (gguf, numpy).
PY_PKGS=(fonttools==4.60.1 onnx==1.23.2 gguf==0.19.0 numpy==2.4.6)

# Model inputs: where the streams keep them, and where to fetch them if absent.
# All are checked against straylight/inputs.sha256 before use.
QWEN_SRC=streams/asr/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-Q4_K_M.gguf
QWEN_URL=https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/resolve/main/Qwen3-ASR-0.6B-Q4_K_M.gguf
SILERO_SRC=streams/asr/downloads/models/silero-vad-v6.2/silero-vad-v6.2-F32.gguf
SILERO_URL=https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/main/silero-vad-v6.2-F32.gguf
MEL_SRC=streams/wakeword/downloads/models/melspectrogram.onnx
MEL_URL=https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx
EMB_SRC=streams/wakeword/downloads/models/embedding_model.onnx
EMB_URL=https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx
# Trained by the wakeword stream (streams/wakeword/scripts/train.py, run v5);
# not downloadable.
WAKE_SRC=streams/wakeword/work/models/v5-final/hey-straylight.slt
