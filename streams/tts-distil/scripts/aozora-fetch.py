#!/usr/bin/env python3
"""Pick public-domain Aozora Bunko works (Japanese originals, modern kana and
kanji, no rights flag on the work or on any person credited) by a few authors
with plain modern prose, and download their text archives.

    aozora-fetch.py CATALOGUE.csv OUTDIR [N_WORKS]

Writes OUTDIR/<work id>.zip and OUTDIR/works.tsv (id, author, title, URL,
sha256)."""
import csv, hashlib, os, random, sys, time, urllib.request
from collections import defaultdict

AUTHORS = {"宮沢 賢治", "芥川 竜之介", "夏目 漱石", "太宰 治", "新美 南吉", "小川 未明",
           "寺田 寅彦", "坂口 安吾", "岡本 綺堂", "海野 十三", "豊島 与志雄", "林 芙美子",
           "岸田 国士", "織田 作之助", "佐藤 垢石"}

def main():
    cat, out = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 160
    rows = defaultdict(list)
    for r in csv.DictReader(open(cat, encoding="utf-8-sig")):
        rows[r["作品ID"]].append(r)
    picks = []
    for wid, rs in rows.items():
        r0 = rs[0]
        if r0["文字遣い種別"] != "新字新仮名" or r0["作品著作権フラグ"] != "なし" or r0["原題"]:
            continue
        if any(r["人物著作権フラグ"] != "なし" for r in rs):
            continue
        if any(r["役割フラグ"] != "著者" for r in rs):
            continue  # translators, editors: skip
        name = f"{r0['姓']} {r0['名']}"
        if name not in AUTHORS or not r0["テキストファイルURL"].endswith(".zip"):
            continue
        if "aozora.gr.jp" not in r0["テキストファイルURL"]:
            continue
        picks.append((wid, name, r0["作品名"], r0["テキストファイルURL"]))
    random.Random(1).shuffle(picks)
    picks = sorted(picks[:n])
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "works.tsv"), "w", encoding="utf-8") as f:
        for wid, name, title, url in picks:
            p = os.path.join(out, f"{wid}.zip")
            if not os.path.exists(p):
                req = urllib.request.Request(url, headers={"User-Agent": "corpus-fetch/1.0"})
                data = urllib.request.urlopen(req, timeout=60).read()
                open(p, "wb").write(data)
                time.sleep(1.0)
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            f.write(f"{wid}\t{name}\t{title}\t{url}\t{h}\n")
            print(wid, name, title, file=sys.stderr)

main()
