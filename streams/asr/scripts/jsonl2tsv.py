"""transcribe-cli --batch-jsonl output -> id<TAB>text (id = wav basename)."""
import json
import os
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    j = json.loads(line)
    if "file" in j:
        uid = os.path.basename(j["file"]).removesuffix(".wav")
        print(f"{uid}\t{j.get('text', '').replace(chr(9), ' ').replace(chr(10), ' ')}")
