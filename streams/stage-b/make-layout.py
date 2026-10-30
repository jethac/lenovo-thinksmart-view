#!/usr/bin/env python3
"""Generate the stage-B GPT layout (layout.sfdisk) from the stock sfdisk dump.

p1-p23 are copied unchanged. p24 'system' keeps its start, UUID, type and
attributes and grows. persist, syscfg, mcfg, apdp and msadp move to the end of
the disk as p25-p29, each with its stock size, type, UUID and attributes, each
starting on a 1 MiB (2048-sector) boundary. Everything else is dropped.

Usage: make-layout.py STOCK.sfdisk > layout.sfdisk
"""
import re
import sys

ALIGN = 2048                      # 1 MiB in 512-byte sectors
KEEP_LOW = range(1, 24)           # p1-p23, unchanged
TAIL = ["persist", "syscfg", "mcfg", "apdp", "msadp"]


def parse(path):
    header, parts = [], []
    for line in open(path):
        line = line.rstrip("\n")
        m = re.match(r"^\S+ : (.*)$", line)
        if not m:
            if line.strip():
                header.append(line)
            continue
        fields = {}
        for kv in re.findall(r'(\w[\w-]*)=\s*("[^"]*"|[^,]+)', m.group(1)):
            fields[kv[0]] = kv[1].strip()
        parts.append(fields)
    return header, parts


def fmt(n, p):
    s = (f"/dev/mmcblk0p{n} : start={int(p['start']):>12}, size={int(p['size']):>12}, "
         f"type={p['type']}, uuid={p['uuid']}, name={p['name']}")
    if "attrs" in p:
        s += f", attrs={p['attrs']}"
    return s


def main():
    header, parts = parse(sys.argv[1])
    hdr = dict(h.split(": ", 1) for h in header)
    by_name = {p["name"].strip('"'): p for p in parts}
    last_lba = int(hdr["last-lba"])

    # Tail, laid out backwards from the last 1 MiB boundary that fits below
    # last-lba (the backup GPT entries start at last-lba + 1).
    end = (last_lba + 1) // ALIGN * ALIGN
    slots = [(name, -(-int(by_name[name]["size"]) // ALIGN) * ALIGN) for name in TAIL]
    tail_start = end - sum(s for _, s in slots)
    assert tail_start % ALIGN == 0

    out = [f"label: {hdr['label']}", f"label-id: {hdr['label-id']}",
           "device: /dev/mmcblk0", "unit: sectors",
           f"first-lba: {hdr['first-lba']}", f"last-lba: {hdr['last-lba']}",
           f"table-length: {hdr['table-length']}", f"sector-size: {hdr['sector-size']}", ""]
    for n in KEEP_LOW:
        out.append(fmt(n, parts[n - 1]))
    system = dict(parts[23])
    assert system["name"] == '"system"' and int(system["start"]) == 923648
    system["size"] = str(tail_start - int(system["start"]))
    assert int(system["size"]) % ALIGN == 0
    out.append(fmt(24, system))
    pos = tail_start
    for i, (name, slot) in enumerate(slots):
        p = dict(by_name[name])
        p["start"] = str(pos)
        out.append(fmt(25 + i, p))
        pos += slot
    assert pos <= last_lba + 1
    print("\n".join(out))


if __name__ == "__main__":
    main()
