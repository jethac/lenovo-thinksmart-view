#!/usr/bin/env python3
"""Reference phonemes and audio from Python kokoro/misaki (laptop only).

    kokoro-reference.py phonemes LINES.tsv OUT.tsv
        id, lang, text -> id, lang, misaki phonemes, token ids (Kokoro v1.0 vocab)
    kokoro-reference.py render LINES.tsv OUTDIR VOICE[,VOICE...] [--ids a,b]
        WAV per voice and line (KModel, PyTorch, CPU), OUTDIR/<voice>-<id>.wav
        A voice may be a blend: "af_heart*0.7+jf_alpha*0.3".

Lines are tab-separated: id, lang (en, ja, zh), text. Run with the venv in
downloads/kokoro-venv (kokoro 0.9.4, misaki 0.9.4, UniDic 3.1.0 for the
Japanese path, spaCy en_core_web_sm for English).
"""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
DL = os.path.join(HERE, "..", "downloads", "kokoro", "hexgrad")
LANG = {"en": "a", "ja": "j", "zh": "z"}

def lines(path):
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if ln and not ln.startswith("#"):
            i, l, t = ln.split("\t", 2)
            yield i, l, t

def vocab():
    return json.load(open(os.path.join(DL, "config.json")))["vocab"]

_pipes = {}
def pipe(lang, model=False):
    from kokoro import KPipeline
    k = (lang, id(model))
    if k not in _pipes:
        _pipes[k] = KPipeline(lang_code=LANG[lang], repo_id="hexgrad/Kokoro-82M", model=model)
    return _pipes[k]

def phonemes(lang, text):
    """Phonemes as KPipeline produces them: one string per chunk."""
    out = []
    for r in pipe(lang)(text):
        out.append(r.phonemes)
    return out

def voice_tensor(spec):
    import torch
    parts = []
    for p in spec.split("+"):
        name, _, w = p.partition("*")
        v = torch.load(os.path.join(DL, "voices", name + ".pt"), weights_only=True)
        parts.append((v, float(w) if w else 1.0))
    tot = sum(w for _, w in parts)
    return sum(v * (w / tot) for v, w in parts)

def main():
    mode = sys.argv[1]
    if mode == "phonemes":
        voc = vocab()
        with open(sys.argv[3], "w", encoding="utf-8") as f:
            for i, l, t in lines(sys.argv[2]):
                ps = " ".join(phonemes(l, t))
                ids = [voc[c] for c in ps if c in voc]
                f.write(f"{i}\t{l}\t{ps}\t{' '.join(map(str, ids))}\n")
                print(i, ps, file=sys.stderr)
    elif mode == "render":
        import numpy as np, soundfile as sf, torch
        from kokoro import KModel
        torch.manual_seed(0)
        outdir, voices = sys.argv[3], sys.argv[4].split(",")
        only = None
        if "--ids" in sys.argv:
            only = set(sys.argv[sys.argv.index("--ids") + 1].split(","))
        os.makedirs(outdir, exist_ok=True)
        model = KModel(config=os.path.join(DL, "config.json"), model=os.path.join(DL, "kokoro-v1_0.pth")).eval()
        voc = vocab()
        for vs in voices:
            pack = voice_tensor(vs)
            for i, l, t in lines(sys.argv[2]):
                if only and i not in only:
                    continue
                audio = []
                for ps in phonemes(l, t):
                    ids = [voc[c] for c in ps if c in voc]
                    ref = pack[len(ids) - 1]
                    with torch.no_grad():
                        a = model(ps, ref, 1.0)
                    audio.append(a.numpy())
                name = vs.replace("*", "x").replace("+", "_")
                sf.write(os.path.join(outdir, f"{name}-{i}.wav"), np.concatenate(audio), 24000, subtype="PCM_16")
                print(name, i, file=sys.stderr)
    else:
        sys.exit(__doc__)

if __name__ == "__main__":
    main()
