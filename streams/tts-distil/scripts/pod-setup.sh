#!/bin/sh
# On the PGX: prepare a RunPod pod (runpod/pytorch 2.8 / CUDA 12.8 image) for
# the narrow-student jobs, in the PGX's /w layout. The PGX's uplink is slow
# (about 60 KB/s to the pods), so only our code and phoneme lists go up (a
# small tarball); the pod fetches Kokoro-82M v1.0 from Hugging Face (checked
# against the PGX copy's SHA-256), Paradee from GitHub at the pinned commit,
# and the Python packages itself. Teacher corpora are rendered on the pod.
#   pod-setup.sh HOST PORT LANG...
set -eu
H=$1 P=$2; shift 2
S="ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -p $P root@$H"
cd "$HOME/straylight-tts"
tar czf /tmp/tts-distil-pod.tgz src/kokoro_pkg src/paradee src/utmos.py src/synth-paradee.py src/corpus/en.phon.tsv src/corpus/ja.phon.tsv src/corpus/zh.phon.tsv \
  data/eval-en.phon.tsv data/eval-ja.phon.tsv data/eval-zh.phon.tsv data/accent-ja.phon.tsv
scp -q -P "$P" /tmp/tts-distil-pod.tgz root@$H:/tmp/
$S 'set -e; mkdir -p /w/downloads/hexgrad/voices /w/logs /w/eval /w/export; cd /w && tar xzf /tmp/tts-distil-pod.tgz
  (apt-get -qq update && apt-get -qq install -y rsync) >/dev/null 2>&1
  pip install -q transformers==4.57.1 soundfile loguru scipy onnx onnxruntime 2>&1 | grep -v notice || true
  git config --global --add safe.directory "*"
  B=https://huggingface.co/hexgrad/Kokoro-82M/resolve/main
  cd /w/downloads/hexgrad
  for f in config.json kokoro-v1_0.pth voices/af_heart.pt voices/jf_alpha.pt voices/zf_xiaoni.pt; do curl -sSfL -o $f $B/$f; done
  sha256sum kokoro-v1_0.pth config.json | cut -c1-20
  [ -d /w/downloads/paradee/src ] || git clone -q https://github.com/sahilmahendrakar/paradee.git /w/downloads/paradee/src
  git -C /w/downloads/paradee/src checkout -q aae3cc46657bc69c6dbf9573bba556fb233f6bc0'
for L in "$@"; do $S "cd /w && sh src/paradee/setup.sh /w/downloads/paradee/src /w/paradee/$L >/dev/null && echo $L ready"; done
