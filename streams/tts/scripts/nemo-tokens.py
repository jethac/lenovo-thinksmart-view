"""Tokenise the listening lines with NeMo's own tokenizer, as do_tts() does.

    nemo-tokens.py TOKENIZER_DIR LANG TEXT_FILE

TOKENIZER_DIR is the extracted .nemo (model_config.yaml and dictionaries).
Prints one line per utterance in the same format as magpie-tokens (chunks
separated by " | ").
"""
import re, sys
from pathlib import Path

import yaml
from omegaconf import OmegaConf
from nemo.collections.tts.data.text_to_speech_dataset_lhotse import setup_tokenizers
from nemo.collections.tts.models.magpietts import get_tokenizer_for_language, chunk_text_for_inference

root, lang, textfile = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

def resolve(v):
    if isinstance(v, dict): return {k: resolve(x) for k, x in v.items()}
    if isinstance(v, list): return [resolve(x) for x in v]
    if isinstance(v, str) and v.startswith("nemo:"): return str(root / v.split(":", 1)[1])
    return v

cfg = resolve(yaml.safe_load(open(root / "model_config.yaml", encoding="utf-8")))
tok = setup_tokenizers(OmegaConf.create(cfg["text_tokenizers"]), mode="test",
                       cfg_nemo_version=cfg.get("nemo_version"))
name = get_tokenizer_for_language(lang, list(tok.tokenizers.keys()),
                                  language_tokenizer_map=cfg.get("language_to_tokenizer_mapping"))
eos = len(tok.tokens) + 1   # as in MagpieTTSModel (num text tokens + 1)
for line in open(textfile, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line: continue
    if lang == "ja": line = re.sub(r"\s+", "", line)   # as do_tts()
    chunks, lens, _ = chunk_text_for_inference(text=line, language=lang, tokenizer_name=name,
                                               text_tokenizer=tok, eos_token_id=eos)
    print(" | ".join(" ".join(map(str, c[:n].tolist())) for c, n in zip(chunks, lens)))
