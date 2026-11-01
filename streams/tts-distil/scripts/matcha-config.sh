#!/bin/sh
# Matcha configs (data, experiment) for one language, from its stats.json:
#   matcha-config.sh MATCHA_TREE LANG
set -eu
cd "$1"
L=$2
  python - "$L" <<'EOF'
import json, sys
L = sys.argv[1]
st = json.load(open(f"/w/data/train-{L}/stats.json"))
open(f"configs/data/kokoro_{L}.yaml", "w").write(f"""_target_: matcha.data.text_mel_datamodule.TextMelDataModule
name: kokoro_{L}
train_filelist_path: /w/data/train-{L}/train.txt
valid_filelist_path: /w/data/train-{L}/valid.txt
batch_size: 32
num_workers: 5
pin_memory: True
cleaners: []
add_blank: True
n_spks: 1
n_fft: 1024
n_feats: 80
sample_rate: 22050
hop_length: 256
win_length: 1024
f_min: 0
f_max: 8000
data_statistics:
  mel_mean: {st['mel_mean']:.6f}
  mel_std: {st['mel_std']:.6f}
seed: ${{seed}}
load_durations: true
""")
open(f"configs/experiment/kokoro_{L}.yaml", "w").write(f"""# @package _global_
defaults:
  - override /data: kokoro_{L}.yaml
tags: ["kokoro_{L}"]
run_name: kokoro_{L}
test: False
trainer:
  precision: bf16-mixed
  check_val_every_n_epoch: 5
callbacks:
  model_checkpoint:
    every_n_epochs: null
    every_n_train_steps: 10000
    save_top_k: -1
    monitor: null
""")
EOF
