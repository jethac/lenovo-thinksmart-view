"""Per-clip latency and real-time factor from transcribe-cli --batch-jsonl output.

    summarise-device.py RESULT.jsonl REFS.tsv
Prints n, median/max of (mel+encode+decode) ms, median encode and decode ms,
median audio length and median RTF (processing time / audio time)."""
import json, statistics as st, sys, wave, os
res, refs = sys.argv[1], sys.argv[2]
dur = {}
for line in open(refs, encoding="utf-8"):
    cid, wav, _ = line.rstrip("\n").split("\t", 2)
    with wave.open(wav) as w: dur[cid] = w.getnframes() / w.getframerate()
rows = []
for line in open(res, encoding="utf-8"):
    d = json.loads(line)
    if "file" not in d: continue
    cid = os.path.splitext(os.path.basename(d["file"]))[0]
    t = d.get("mel_ms", 0) + d.get("encode_ms", 0) + d.get("decode_ms", 0)
    rows.append((t, d.get("encode_ms", 0), d.get("decode_ms", 0), dur[cid]))
tot = [r[0] for r in rows]
print(f"n={len(rows)} audio_med={st.median(r[3] for r in rows):.1f}s "
      f"latency_med={st.median(tot)/1000:.2f}s max={max(tot)/1000:.2f}s "
      f"encode_med={st.median(r[1] for r in rows)/1000:.2f}s decode_med={st.median(r[2] for r in rows)/1000:.2f}s "
      f"RTF_med={st.median(r[0]/1000/r[3] for r in rows):.2f}")
