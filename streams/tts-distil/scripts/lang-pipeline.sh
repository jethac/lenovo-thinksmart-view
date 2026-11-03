#!/bin/sh
# On a pod: one language's whole student, unattended:
#   1. the teacher corpus (KD workers in parallel), until every shard exists
#   2. stage 1: spectral losses + teacher head distillation (teacher source), S1 steps
#   3. stage 2: GAN + spectral (x10) + head distillation, S2 steps, from stage 1's last snapshot
# Snapshots every 2,000 steps in checkpoints/narrow_WIDTH_s1|_s2 (pulled by the PGX).
#   lang-pipeline.sh LANG VOICE [WIDTH] [S1] [S2] [KD]
set -u
L=$1 V=$2 W=${3:-x25k2} S1=${4:-20000} S2=${5:-30000} KD=${6:-3}
cd /w/paradee/$L
export PYTHONPATH=/w/src/kokoro_pkg PARADEE_VOICE="$V" PARADEE_G2P_TSV=/w/data/eval-$L.phon.tsv
n=$(( ($(grep -c . /w/src/corpus/$L.phon.tsv) + 499) / 500 ))
if [ "$(ls data/teacher 2>/dev/null | grep -c 'pt$')" -lt "$n" ]; then
  i=0; while [ $i -lt "$KD" ]; do KD_PART=$i/$KD KD_REVERSE=${KD_REVERSE:-0} python run.py kd_teacher.py /w/src/corpus/$L.phon.tsv "$V" data/teacher > /w/logs/kd-$L-$i.log 2>&1 & i=$((i + 1)); done
  wait
fi
echo "corpus $(ls data/teacher | grep -c 'pt$')/$n shards"
python run.py scripts/train_narrow.py $W --teacher-source --head-weight 1 --phase-weight 2 --steps $S1 --tag _s1 > /w/logs/$L-s1.log 2>&1
python run.py scripts/train_narrow.py $W --gan --mel-weight 10 --bs 16 --head-weight 1 --phase-weight 2 --steps $S2 --tag _s2 \
  --init-from checkpoints/narrow_${W}_s1/step-$(printf %07d $S1).pt > /w/logs/$L-s2.log 2>&1
echo done
