#!/usr/bin/env python3
# Small reader for Debian archive indices (used by fetch-adbd.sh).
# Run with python3 -I. Inputs are untrusted data; this only parses text.
#
#   debian-index.py release-sha256 RELEASE_TEXT INDEX_PATH
#       print "<sha256> <size>" of INDEX_PATH (e.g. main/binary-arm64/Packages.xz)
#       from the SHA256 section of an already signature-verified Release text.
#   debian-index.py package PACKAGES_TEXT NAME
#       print "<version> <filename> <sha256> <size>" for binary package NAME.
#   debian-index.py source SOURCES_TEXT NAME
#       print "<version> <directory>" then "<sha256> <size> <file>" per file.
import sys


def stanzas(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        cur, key = {}, None
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur:
                    yield cur
                cur, key = {}, None
            elif line[0] in " \t" and key:
                cur[key] += "\n" + line.strip()
            elif ":" in line:
                key, _, val = line.partition(":")
                cur[key] = val.strip()
        if cur:
            yield cur


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__ or "usage")
    cmd, path, arg = argv[1:]
    if cmd == "release-sha256":
        for st in stanzas(path):
            for line in st.get("SHA256", "").splitlines():
                parts = line.split()
                if len(parts) == 3 and parts[2] == arg:
                    print(parts[0], parts[1])
                    return
        sys.exit(f"{arg} not in Release SHA256 list")
    if cmd == "package":
        hits = [s for s in stanzas(path) if s.get("Package") == arg]
        if len(hits) != 1:
            sys.exit(f"{arg}: {len(hits)} entries in index")
        s = hits[0]
        print(s["Version"], s["Filename"], s["SHA256"], s["Size"])
        return
    if cmd == "source":
        hits = [s for s in stanzas(path) if s.get("Package") == arg]
        if len(hits) != 1:
            sys.exit(f"{arg}: {len(hits)} entries in index")
        s = hits[0]
        print(s["Version"], s["Directory"])
        for line in s["Checksums-Sha256"].splitlines():
            if line.strip():
                print(line.strip())
        return
    sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
