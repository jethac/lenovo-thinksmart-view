#!/usr/bin/env python3
"""Laptop renders for the real-time TTS bake-off: the lines of
cases/rt-lines.tsv for one model and voice, into
work/rt-samples/<model>/<voice>-<lang>-<n>.wav (n = the line's name after
the language, e.g. en-cal -> en-cal).

    rt-render.py piper MODEL.onnx SYMBOLS.tsv OUTDIR VOICE [SPEAKER_ID]
        SYMBOLS.tsv: `STRAYLIGHT_G2P_FORMAT=piper straylight-listen --g2p`
        (id, lang, symbols joined by '|'), i.e. the device's own front end.
    rt-render.py matcha SHERPA_DIR VOCOS.onnx SYMBOLS.tsv OUTDIR VOICE
    rt-render.py supertonic SHERPA_DIR LINES.tsv OUTDIR VOICE SID LANGS
    rt-render.py sherpa-vits MODEL_DIR LINES.tsv OUTDIR VOICE SID LANGS   (MeloTTS, AISHELL-3 icefall: lexicon front ends)
    rt-render.py voicevox CORE_DIR ORT_LIB DICT VVM STYLE LINES.tsv OUTDIR VOICE

Text models get the lines with the lexicon's aliases applied (ai& as
エーアイアンド / 诶爱安德 / "A-I, and").
"""
import json, os, sys, time
import numpy as np
import soundfile as sf

ALIAS = {"ja": "エーアイアンド", "zh": "诶爱安德", "en": "A-I, and"}


def lines(path):
    for l in open(path, encoding="utf-8"):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 3 and not l.startswith("#"):
            yield f


def name(i):
    return i  # en-cal etc.


def piper_ids(cfg, syms):
    m = cfg["phoneme_id_map"]
    pinyin = cfg.get("phoneme_type") == "pinyin"
    ids = list(m["^"])
    if not pinyin:
        ids += m["_"]
        for s in syms:
            if s in m:
                ids += m[s] + m["_"]
        return ids + m["$"]
    inits = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    for s in syms:
        if s[-1:].isdigit():
            base, tone = s[:-1], s[-1]
            ini = next((c for c in inits if base.startswith(c)), "")
            fin = base[len(ini):]
            for p in (ini or "Ø", fin, tone):
                ids += m.get(p, [])
            ids += m["_"]
        elif s in m:
            ids += m[s] + m["_"]
    return ids + m["$"]


def main():
    kind = sys.argv[1]
    a = sys.argv[2:]
    if kind == "piper":
        import onnxruntime as ort
        model, symtsv, out, voice = a[:4]
        sid = int(a[4]) if len(a) > 4 else None
        cfg = json.load(open(model.replace("-dur.onnx", ".onnx") + ".json" if os.path.exists(model.replace("-dur.onnx", ".onnx") + ".json") else model + ".json"))
        inf = cfg["inference"]
        s = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
        os.makedirs(out, exist_ok=True)
        for f in lines(symtsv):
            syms = f[2].split("|")
            ids = piper_ids(cfg, syms)
            feeds = {"input": np.array([ids], np.int64), "input_lengths": np.array([len(ids)], np.int64),
                     "scales": np.array([inf["noise_scale"], inf["length_scale"], inf["noise_w"]], np.float32)}
            if sid is not None:
                feeds["sid"] = np.array([sid], np.int64)
            y = s.run(None, feeds)[0].reshape(-1)
            sf.write(f"{out}/{voice}-{name(f[0])}.wav", y, cfg["audio"]["sample_rate"], subtype="PCM_16")
        return
    import sherpa_onnx as so
    if kind == "matcha":
        d, vocos, symtsv, out, voice = a[:5]
        t = so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(matcha=so.OfflineTtsMatchaModelConfig(
            acoustic_model=d + "/model-steps-3.onnx", vocoder=vocos, tokens=d + "/tokens.txt"), num_threads=4)))
        os.makedirs(out, exist_ok=True)
        for f in lines(symtsv):
            if f[1] != "en":
                continue
            g = so.GenerationConfig()
            g.phoneme_codepoints = [[ord(c) for c in "".join(f[2].split("|"))]]
            r = t.generate("x", g)
            sf.write(f"{out}/{voice}-{name(f[0])}.wav", np.array(r.samples), r.sample_rate, subtype="PCM_16")
        return
    if kind in ("supertonic", "sherpa-vits"):
        d, ltsv, out, voice, sid, langs = a[:6]
        if kind == "supertonic":
            mc = so.OfflineTtsModelConfig(supertonic=so.OfflineTtsSupertonicModelConfig(
                *[f"{d}/{n}.int8.onnx" for n in ("duration_predictor", "text_encoder", "vector_estimator", "vocoder")],
                d + "/tts.json", d + "/unicode_indexer.bin", d + "/voice.bin"), num_threads=4)
        else:
            m = [x for x in ("model.onnx", "vits-aishell3.onnx") if os.path.exists(f"{d}/{x}")][0]
            mc = so.OfflineTtsModelConfig(vits=so.OfflineTtsVitsModelConfig(model=f"{d}/{m}", lexicon=d + "/lexicon.txt", tokens=d + "/tokens.txt",
                                                                             dict_dir=d + "/dict" if os.path.isdir(d + "/dict") else ""), num_threads=4)
        t = so.OfflineTts(so.OfflineTtsConfig(model=mc, max_num_sentences=10))
        os.makedirs(out, exist_ok=True)
        for f in lines(ltsv):
            if f[1] not in langs.split(","):
                continue
            g = so.GenerationConfig()
            g.sid = int(sid)
            if kind == "supertonic":
                g.num_steps = 5
                g.extra = {"lang": f[1]}
            r = t.generate(f[2].replace("ai&", ALIAS[f[1]]), g)
            sf.write(f"{out}/{voice}-{name(f[0])}.wav", np.array(r.samples), r.sample_rate, subtype="PCM_16")
        return
    if kind == "voicevox":
        from voicevox_core.blocking import Onnxruntime, OpenJtalk, Synthesizer, VoiceModelFile
        core, ortlib, dic, vvm, style, ltsv, out, voice = a[:8]
        syn = Synthesizer(Onnxruntime.load_once(filename=ortlib), OpenJtalk(dic), cpu_num_threads=4)
        with VoiceModelFile.open(vvm) as m:
            syn.load_voice_model(m)
        os.makedirs(out, exist_ok=True)
        for f in lines(ltsv):
            if f[1] != "ja":
                continue
            w = syn.tts(f[2].replace("ai&", ALIAS["ja"]), int(style))
            open(f"{out}/{voice}-{name(f[0])}.wav", "wb").write(w)
        return
    sys.exit(f"unknown kind {kind}")


main()
