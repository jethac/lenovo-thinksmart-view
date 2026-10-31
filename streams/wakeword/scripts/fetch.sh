#!/usr/bin/env bash
# Downloads for the wake-word stream, into downloads/ (git-ignored).
#
#   fetch.sh [code|models|negatives|musan|all]
#
# Room reverb is simulated (scripts/make-rirs.py, pyroomacoustics), not downloaded.
# negatives: openWakeWord's precomputed ACAV100M features are 17.3 GB
# (5,625,000 rows of 16x96 float16, 1.28 s each). Only six slices of
# 250,000 rows spread over the file are fetched with HTTP range requests
# (6 x 768 MB, about 533 h of audio), read as raw float16 by train.py. The false-positive validation set (11 h) is fetched whole.
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
D=$S/downloads
mkdir -p "$D"
what=${1:-all}
HF=https://huggingface.co

code() {
    [[ -d $D/openWakeWord ]] || git clone git@github.com:dscripka/openWakeWord.git "$D/openWakeWord"
    [[ -d $D/piper-sample-generator ]] || git clone git@github.com:rhasspy/piper-sample-generator.git "$D/piper-sample-generator"
}

models() {
    mkdir -p "$D/models"
    for f in melspectrogram.onnx embedding_model.onnx; do
        [[ -s $D/models/$f ]] || curl -fL -o "$D/models/$f" \
            "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/$f"
    done
    [[ -s $D/models/en_US-libritts_r-medium.pt ]] || curl -fL -o "$D/models/en_US-libritts_r-medium.pt" \
        "https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt"
    cp "$D/piper-sample-generator/models/en_US-libritts_r-medium.pt.json" "$D/models/"
    sha256sum "$D"/models/*.onnx "$D"/models/*.pt > "$D/models/SHA256SUMS.local"
}

negatives() {
    mkdir -p "$D/negatives"
    local u=$HF/datasets/davidscripka/openwakeword_features/resolve/main
    [[ -s $D/negatives/validation_set_features.npy ]] || \
        curl -fL -o "$D/negatives/validation_set_features.npy" "$u/validation_set_features.npy"
    local row=3072 hdr=128 n=250000
    for k in 0 1 2 3 4 5; do
        local first=$((k * 900000))
        local a=$((hdr + first * row)) b=$((hdr + (first + n) * row - 1))
        local f=$D/negatives/acav-slice-$k.f16
        if [[ ! -s $f || $(stat -c %s "$f") -ne $((n * row)) ]]; then
            curl -fsSL -r "$a-$b" -o "$f" "$u/openwakeword_features_ACAV100M_2000_hrs_16bit.npy"
        fi
    done
}

musan() {
    # MUSAN (CC BY 4.0), Hugging Face parquet copy: all noise, music shards 0-2
    # (0-1 for augmentation, 2 held out for false-accept tests), speech shards
    # 0-1 (general speech negatives for the model without ACAV100M).
    mkdir -p "$D/musan"
    local u=$HF/datasets/corypaik/musan/resolve/main
    for f in noise/train-00000-of-00002 noise/train-00001-of-00002 \
             music/train-00000-of-00010 music/train-00001-of-00010 music/train-00002-of-00010 \
             speech/train-00000-of-00014 speech/train-00001-of-00014; do
        local o=$D/musan/${f//\//-}.parquet
        [[ -s $o ]] || curl -fsSL -o "$o" "$u/$f.parquet"
    done
}

case $what in
code) code ;; models) models ;; negatives) negatives ;; musan) musan ;;
all) code; models; musan; negatives ;;
*) echo "usage: $0 [code|models|negatives|musan|all]" >&2; exit 2 ;;
esac
