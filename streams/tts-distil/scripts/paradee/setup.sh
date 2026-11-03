#!/bin/sh
# One Paradee working directory per voice (run on the PGX, in the training
# image): upstream training/scripts at the pinned commit, with the teacher
# loaded through teacher_shim.py (our Kokoro build and voice blend) and CUDA
# as the default device.
#   setup.sh UPSTREAM_CLONE DEST
set -eu
SRC=$1 DEST=$2
COMMIT=aae3cc46657bc69c6dbf9573bba556fb233f6bc0
HERE=$(cd "$(dirname "$0")" && pwd)
test "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT"
mkdir -p "$DEST/scripts" "$DEST/data" "$DEST/checkpoints"
cp "$SRC"/training/scripts/*.py "$DEST/scripts/"
cp "$HERE/teacher_shim.py" "$HERE/run.py" "$HERE/kd_teacher.py" "$DEST/"
cp "$HERE/teacher_shim.py" "$HERE/narrow.py" "$HERE/train_narrow.py" "$DEST/scripts/"
cd "$DEST/scripts"
sed -i 's/^from kokoro import KPipeline$/from teacher_shim import KPipeline/' common.py
grep -q "from teacher_shim import KPipeline" common.py
sed -i 's/default="mps"/default="cuda"/' train_text.py train_decoder.py train_vhead.py eval_full.py
sed -i 's/if DEV == "mps": torch.mps.synchronize()/if DEV == "cuda": torch.cuda.synchronize()/' train_decoder.py
! grep -q '"mps"' train_text.py train_decoder.py train_vhead.py
# The export also returns each input token's duration in 600-sample frames
# (pads included), as straylight-listen's Kokoro export does ("durations").
sed -i 's/        return self.head(self.trunk(asr_tok @ aln, F0, N), F0)$/        return self.head(self.trunk(asr_tok @ aln, F0, N), F0), n.float()/' export_paradee_v1_1.py
sed -i 's/output_names=\["waveform"\],/output_names=["waveform", "durations"],/' export_paradee_v1_1.py
sed -i 's/dynamic_axes={"input_ids": {1: "tokens"}, "waveform": {1: "samples"}}/dynamic_axes={"input_ids": {1: "tokens"}, "waveform": {1: "samples"}, "durations": {0: "tokens"}}/' export_paradee_v1_1.py
sed -i 's/vs {yt.shape\[1\]}/vs {yt[0].shape[1]}/' export_paradee_v1_1.py
grep -q '"durations": {0: "tokens"}' export_paradee_v1_1.py
grep -q 'n.float()$' export_paradee_v1_1.py
grep -q 'yt\[0\].shape' export_paradee_v1_1.py
echo ok
