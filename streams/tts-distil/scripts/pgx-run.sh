#!/bin/sh
# On the PGX: one training-image container, nice 10, capped (48 GB RAM,
# 6 CPUs, a GPU memory fraction), ~/straylight-tts mounted at /w. Detached;
# output in ~/straylight-tts/logs/NAME.log.
#   pgx-run.sh NAME GPU_FRACTION CMD...
name=$1 frac=$2; shift 2
cd "$HOME/straylight-tts" || exit 1
docker rm -f "$name" >/dev/null 2>&1
docker run -d --name "$name" --gpus all --ipc=host --memory=48g --cpus=6 \
  -e TORCH_MEM_FRACTION="$frac" -e HF_HUB_OFFLINE=1 -e HOME=/w/home -e PYTHONUNBUFFERED=1 \
  -u "$(id -u):$(id -g)" -v "$HOME/straylight-tts:/w" -w /w straylight-tts:1 \
  nice -n 10 "$@" > /dev/null
setsid nohup docker logs -f "$name" > "logs/$name.log" 2>&1 < /dev/null &
echo "$name started"
