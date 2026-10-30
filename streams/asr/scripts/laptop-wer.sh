#!/usr/bin/env bash
# Accuracy of every Qwen3-ASR quant on the en/ja sets with the native build
# (timing on the laptop is not meaningful; only the transcripts are used).
#   laptop-wer.sh QUANT...
set -euo pipefail
S=$(cd "$(dirname "$0")/.." && pwd)
CLI=$S/work/build-native/bin/transcribe-cli
R=$S/work/results/laptop; mkdir -p "$R"
for q in "$@"; do
    for set in en-wer ja-cer; do
        cut -f2 "$S/work/testset/$set/refs.tsv" > "$R/$set.list"
        "$CLI" -q --threads 2 --n-ctx 2048 -m "$S/downloads/models/qwen3-asr-0.6b/Qwen3-ASR-0.6B-$q.gguf" \
            --batch "$R/$set.list" --batch-jsonl > "$R/qwen3-$q-$set.jsonl" 2>/dev/null
        python3 -I "$S/scripts/jsonl2tsv.py" "$R/qwen3-$q-$set.jsonl" > "$R/qwen3-$q-$set.tsv"
    done
done
