#!/bin/sh
# On the PGX: two pods render one language's teacher corpus from opposite
# ends; every 2 minutes copy each one's finished shards to the other (pod to
# pod, with the PGX's key forwarded), until both have all N. Then stop the
# first pod's pipeline (the second trains).
#   sync-shards.sh LANG N HOST1:PORT1 HOST2:PORT2
L=$1 N=$2; a=$3; b=$4
eval "$(ssh-agent -s)" >/dev/null; ssh-add -q "$HOME/.ssh/id_ed25519"
ha=${a%:*} pa=${a#*:} hb=${b%:*} pb=${b#*:}
D=/w/paradee/$L/data/teacher
R="rsync -a --ignore-existing --exclude '*.tmp' -e 'ssh -o StrictHostKeyChecking=no -p $pb'"
while :; do
  ssh -A -p "$pa" root@"$ha" "$R $D/ root@$hb:$D/; $R root@$hb:$D/ $D/" 2>/dev/null
  na=$(ssh -p "$pa" root@"$ha" "ls $D | grep -c 'pt\$'"); nb=$(ssh -p "$pb" root@"$hb" "ls $D | grep -c 'pt\$'")
  echo "$(date -u +%H:%M) $na $nb"
  if [ "$nb" -ge "$N" ]; then
    ssh -p "$pa" root@"$ha" 'for p in $(pgrep -f lang-pipeline.sh) $(pgrep -f kd_teacher.py) $(pgrep -f train_narrow.py); do kill $p; done'
    echo "complete on $hb; $ha stopped"; break
  fi
  sleep 120
done
ssh-agent -k >/dev/null
