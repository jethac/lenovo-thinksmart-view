#!/bin/bash
# Pull renders from the PGX (~/straylight-tts/eval/NAME) and run eval.py
# (ASR round trip, WER/CER, distance and timbre against the teacher's
# renders, eval/kokoro-LANG) on the laptop.  Results: work/eval/LANG-TAG.tsv
#   eval-local.sh LANG TAG NAME...
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
L=$1 tag=$2; shift 2
cd "$HERE/work/eval"
for n in kokoro-$L "$@"; do [[ -d $n && $n != narrow-* ]] || rsync -a --exclude .done -e "ssh -o HostName=thinkstationpgx-00b4" "pgx:straylight-tts/eval/$n" ./; done
mkdir -p tmp
TMPDIR=$PWD/tmp /home/jethac/Projects/lenovo-8/streams/tts/downloads/kokoro-venv/bin/python "$HERE/scripts/eval.py" \
  <(grep -v '^#' "$HERE/cases/eval-lines.tsv" | awk -F'\t' -v L="$L" '$2==L') kokoro-$L "$@" > "$L-$tag.tsv" 2> "$L-$tag.err"
grep '^#' "$L-$tag.tsv"
