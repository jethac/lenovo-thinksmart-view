#!/bin/sh
# Prepare a Matcha-TTS tree for the distilled voices (run on the PGX, in the
# training image): copy of shivammehta25/Matcha-TTS at the pinned commit,
# with the input symbols replaced by Kokoro's phoneme vocabulary (same IDs),
# begin/end marks ^ (178) and $ (179) around every input, and configs per
# language.
#   matcha-setup.sh SRC_CLONE DEST
set -eu
SRC=$1 DEST=$2
COMMIT=bd4d90d93214b37f7a159cf205ae85762c2c10aa
rm -rf "$DEST"
cp -a "$SRC" "$DEST"
git -C "$DEST" checkout -q "$COMMIT"
cd "$DEST"

python - <<'EOF'
import json
voc = json.load(open("/w/downloads/hexgrad/config.json"))["vocab"]
sym = [f"<unused{i}>" for i in range(180)]
sym[0] = "_"
for c, i in voc.items():
    sym[i] = c
sym[178], sym[179] = "^", "$"
open("matcha/text/symbols.py", "w").write(
    '"""Kokoro-82M v1.0 phoneme vocabulary (index = Kokoro token ID); 0 is the\n'
    'blank, 178/179 the begin/end marks."""\n'
    f"symbols = {sym!r}\n")
# tokens.txt for the device (symbol, ID), as sherpa-onnx's format
with open("tokens.txt", "w") as f:
    f.write("_ 0\n")
    for c, i in sorted(voc.items(), key=lambda x: x[1]):
        f.write(f"{c} {i}\n")
    f.write("^ 178\n$ 179\n")
EOF

python - <<'EOF'
p = "matcha/text/__init__.py"
s = open(p).read()
s = s.replace('''    sequence = []

    clean_text = _clean_text(text, cleaner_names)
    for symbol in clean_text:
        symbol_id = _symbol_to_id[symbol]
        sequence += [symbol_id]
    return sequence, clean_text''', '''    # Kokoro phonemes as the device front end writes them: symbols outside
    # the vocabulary are dropped (as Kokoro's tokenizer does), ^ and $ added.
    clean_text = text
    sequence = [_symbol_to_id["^"]] + [_symbol_to_id[s] for s in text if s in _symbol_to_id] + [_symbol_to_id["$"]]
    return sequence, clean_text''')
open(p, "w").write(s)
EOF

sed -i 's/^n_vocab: 178/n_vocab: 180/' configs/model/matcha.yaml
# Audio through soundfile (this torchaudio has no decoder backend).
python - <<'EOF'
p = "matcha/data/text_mel_datamodule.py"
s = open(p).read()
s = s.replace("        audio, sr = ta.load(filepath)\n",
              "        import soundfile as sf\n        a, sr = sf.read(filepath, dtype='float32')\n        audio = torch.from_numpy(a)[None]\n")
open(p, "w").write(s)
EOF
grep -q "sf.read(filepath" matcha/data/text_mel_datamodule.py
# GPU memory cap (shared machine) and TF32.
python - <<'EOF'
p = "matcha/train.py"
s = open(p).read()
s = s.replace("import hydra\n", "import hydra\nimport os, torch\n"
              "if float(os.environ.get('TORCH_MEM_FRACTION') or 0):\n"
              "    torch.cuda.set_per_process_memory_fraction(float(os.environ['TORCH_MEM_FRACTION']))\n"
              "torch.set_float32_matmul_precision('high')\n", 1)
open(p, "w").write(s)
EOF
grep -q TORCH_MEM_FRACTION matcha/train.py

python setup.py build_ext --inplace > /dev/null
echo ok
