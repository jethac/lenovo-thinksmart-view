#!/bin/sh
# On the PGX: every 5 minutes, pull the narrow students' snapshots, held-out
# WAVs and logs from the pods into paradee/LANG/checkpoints/ and logs/pods/.
#   pull-pods.sh HOST:PORT:LANG[,LANG]...
cd "$HOME/straylight-tts"; mkdir -p logs/pods
while :; do
  for p in "$@"; do
    h=${p%%:*}; r=${p#*:}; port=${r%%:*}; langs=${r#*:}
    for L in $(echo "$langs" | tr , ' '); do
      mkdir -p paradee/$L/checkpoints
      rsync -a --exclude last.pt -e "ssh -o ConnectTimeout=20 -p $port" "root@$h:/w/paradee/$L/checkpoints/narrow_*" paradee/$L/checkpoints/ 2>/dev/null
      rsync -a -e "ssh -o ConnectTimeout=20 -p $port" "root@$h:/w/logs/" logs/pods/ 2>/dev/null
    done
  done
  sleep 300
done
