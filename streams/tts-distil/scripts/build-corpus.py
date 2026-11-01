#!/usr/bin/env python3
"""Text corpus per language for distilling Kokoro: Common Voice sentence
lists (CC0), Aozora Bunko (public domain, Japanese) and the project's own
assistant-style lines.

    build-corpus.py DOWNLOADS/corpora ASSISTANT_DIR OUTDIR

Writes OUTDIR/<lang>.tsv (id, lang, text) and OUTDIR/<lang>.sources.tsv
(id, source file) for en, ja, zh. Selection is deterministic (seed 1).
"""
import glob, io, os, random, re, sys, unicodedata, zipfile

# Target sentence counts per source (about 12-16 h of audio per language).
PLAN = {
    "en": [("cv/en/sentence-collector.txt", 5500), ("cv/en/wiki.en.rerun-2021-11.txt", 4000), ("assistant", 3000)],
    "ja": [("cv/ja/sentence-collector.txt", 8000), ("cv/ja/yumie-text-1.txt", 1400), ("aozora", 4500), ("assistant", 3500)],
    "zh": [("cv/zh-CN/sentence-collector.txt", 520), ("cv/zh-CN/cn.txt", 3000), ("cv/zh-CN/wiki.zh-cn.txt", 7500), ("assistant", 3500)],
}

LEN = {"en": (15, 220), "ja": (6, 70), "zh": (6, 60)}


def ok(lang, s):
    a, b = LEN[lang]
    if not a <= len(s) <= b:
        return False
    if lang == "en":
        return bool(re.fullmatch(r"[A-Za-z0-9 ,.;:!?'\"\-()&$%/]+", s)) and s[0].isupper()
    if lang == "ja":
        if re.search(r"[a-zA-Z]{1,}", s) and random.random() < 0.6:
            return False  # keep some Latin, mostly kana/kanji
        return bool(re.fullmatch(r"[぀-ヿ一-鿿々々ー、。！？「」『』・ 0-9０-９A-Za-zＡ-Ｚａ-ｚ%％]+", s))
    if lang == "zh":
        return bool(re.fullmatch(r"[一-鿿，。！？、；：“”0-9A-Za-z%.]+", s))
    return False


def norm(s):
    s = unicodedata.normalize("NFKC", s.strip()) if False else s.strip()
    return re.sub(r"\s+", " ", s)


def aozora_sentences(d):
    out = []
    for z in sorted(glob.glob(os.path.join(d, "*.zip"))):
        wid = os.path.basename(z)[:-4]
        with zipfile.ZipFile(z) as zf:
            names = [n for n in zf.namelist() if n.endswith(".txt")]
            if not names:
                continue
            t = zf.read(names[0]).decode("cp932", errors="replace")
        # Header: up to the second line of dashes; footer: from 底本：
        parts = re.split(r"\n-{20,}\r?\n", t)
        body = parts[2] if len(parts) >= 3 else parts[-1]
        body = body.split("底本：")[0]
        body = re.sub(r"《[^》]*》", "", body)      # ruby
        body = body.replace("｜", "")
        body = re.sub(r"［＃[^］]*］", "", body)     # notes
        body = body.replace("　", "")
        for para in body.splitlines():
            para = para.strip()
            for s in re.findall(r"[^。！？]*[。！？]", para):
                s = s.strip().strip("「」『』").strip()
                if "※" in s or "〔" in s or "／" in s:
                    continue
                if s.count("「") != s.count("」"):
                    continue
                out.append((f"aozora/{wid}", s))
    return out


def main():
    root, asst, outdir = sys.argv[1:4]
    os.makedirs(outdir, exist_ok=True)
    random.seed(1)
    for lang, plan in PLAN.items():
        lines, seen = [], set()
        for src, n in plan:
            if src == "assistant":
                cand = []
                for l in open(os.path.join(asst, f"{lang}.tsv"), encoding="utf-8"):
                    f = l.rstrip("\n").split("\t")
                    cand.append(("assistant", f[2]))
                pick = cand[:n]
            else:
                if src == "aozora":
                    cand = aozora_sentences(os.path.join(root, "aozora/works"))
                else:
                    cand = [(src, norm(l)) for l in open(os.path.join(root, src), encoding="utf-8")]
                cand = [(a, s) for a, s in cand if ok(lang, s)]
                random.shuffle(cand)
                pick = []
                for a, s in cand:
                    if s in seen:
                        continue
                    seen.add(s)
                    pick.append((a, s))
                    if len(pick) >= n:
                        break
            print(lang, src, len(pick), file=sys.stderr)
            lines += pick
        with open(os.path.join(outdir, f"{lang}.tsv"), "w", encoding="utf-8") as f, \
                open(os.path.join(outdir, f"{lang}.sources.tsv"), "w", encoding="utf-8") as g:
            for i, (src, s) in enumerate(lines):
                f.write(f"{lang}-{i:05d}\t{lang}\t{s}\n")
                g.write(f"{lang}-{i:05d}\t{src}\n")


main()
