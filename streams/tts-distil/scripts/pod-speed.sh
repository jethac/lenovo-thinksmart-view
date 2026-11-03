#!/bin/sh
# On a pod: s/step of the narrow-student stages on 2 shards of LANG's teacher
# corpus (150 steps each), then the test runs removed.   pod-speed.sh LANG VOICE
cd /w/paradee/$1
export PYTHONPATH=/w/src/kokoro_pkg PARADEE_VOICE="$2"
t() { tag=$1; shift; python run.py scripts/train_narrow.py x25k2 --shards 2 --steps 150 --every 100000 --tag "_sp$tag" "$@" 2>&1 | grep -a "^step 150" | sed "s/^/$tag: /"; rm -rf checkpoints/narrow_x25k2_sp$tag; }
t hd16 --head-weight 1 --phase-weight 2
t hd32 --head-weight 1 --phase-weight 2 --bs 32
t gan8 --gan --mel-weight 10 --bs 8
t gan16 --gan --mel-weight 10 --bs 16
t gan32 --gan --mel-weight 10 --bs 32
t hdgan16 --gan --mel-weight 10 --bs 16 --head-weight 1 --phase-weight 2
