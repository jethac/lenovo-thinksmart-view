#!/usr/bin/env python3
"""Print sla-bench JSONL readably: per file the joined text, per phrase its
language, end-of-speech-to-text lag, decode times and text, and the live
text events with their lag behind the audio they cover."""
import json, sys
for fn in sys.argv[1:]:
    for l in open(fn, encoding="utf-8"):
        if not l.startswith("{"): continue
        u = json.loads(l)
        print(u["file"].split("/")[-1], "t_end", u["t_end"], "cpu", u["cpu_audio_s"], u["cpu_s"], "late", u["late_max_ms"],
              "rss file/anon", u["rss_file_mb"], u["rss_anon_mb"])
        print("  TEXT", u["text"])
        for p in u["phrases"]:
            print("  P", p["i"], p["lang"], "lag", round(p["t_done"] - p["t_speech_end"]), "dec", round(p["dec"]), "flush",
                  round(p["enc"]), "own", p["streamed"], p["text"])
        for p in u["partials"]:
            print("    ~", p["i"], p["lang"], "at", round(p["t"]), "lag", round(p["t"] - p["t_cov"]), "cov", round(p["end"]), p["text"])
