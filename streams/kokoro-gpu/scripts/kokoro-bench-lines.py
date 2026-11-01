#!/usr/bin/env python3
"""Phoneme lines (straylight-listen --g2p output: id, lang, phonemes, ms) to
--tts-bench lines (id, lang, phonemes, token IDs), with Kokoro's vocabulary."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
v = json.load(open(os.path.join(HERE, '..', '..', 'tts', 'downloads', 'kokoro', 'hexgrad', 'config.json')))['vocab']
for ln in open(sys.argv[1], encoding='utf-8'):
    f = ln.rstrip('\n').split('\t')
    if len(f) < 3:
        continue
    ids = [str(v[c]) for c in f[2] if c in v]
    print('\t'.join([f[0], f[1], f[2], ' '.join(ids)]))
