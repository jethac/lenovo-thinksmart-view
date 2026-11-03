#!/bin/sh
# On the PGX: evaluate every EVERY-th snapshot of the given runs as it
# appears (eval-narrow.sh: export, render the evaluation lines, UTMOS);
# results appended to logs/watch-eval.log.
#   watch-eval.sh EVERY LANG:WIDTH[:TAG]...
cd "$HOME/straylight-tts"
E=$1; shift
while :; do
  for r in "$@"; do
    L=${r%%:*}; rest=${r#*:}; W=${rest%%:*}; T=$(echo "$rest" | cut -s -d: -f2)
    for f in paradee/$L/checkpoints/narrow_$W$T/step-*.pt; do
      [ -e "$f" ] || continue
      s=$(basename "$f" .pt | sed 's/step-0*//')
      [ $((s % E)) -eq 0 ] || continue
      n=narrow-$L-$W$T-$(printf %07d "$s")
      [ -e "eval/$n/.done" ] && continue
      sh src/eval-narrow.sh "$L" "$W" "$s" "$T" >> logs/watch-eval.log 2>&1 && touch "eval/$n/.done"
    done
  done
  sleep 120
done
