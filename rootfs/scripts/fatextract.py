#!/usr/bin/env python3
"""Minimal read-only FAT12/16/32 reader (no mounting, no root).

Usage:
  fatextract.py IMAGE ls [PATH]          list a directory (recursive with -r)
  fatextract.py IMAGE get PATH OUTFILE   copy one file out

Paths are case-insensitive, '/'-separated. Long file names are supported.
Written for the msm8953 'modem' (/firmware) partition image, which is FAT16.
"""
import struct
import sys


class Fat:
    def __init__(self, path):
        self.f = open(path, "rb")
        bs = self.read(0, 512)
        (self.bps, self.spc, self.rsvd, self.nfats, self.rootents,
         tot16, _media, fatsz16) = struct.unpack_from("<HBHBHHBH", bs, 11)
        tot32, = struct.unpack_from("<I", bs, 32)
        fatsz32, = struct.unpack_from("<I", bs, 36)
        self.fatsz = fatsz16 or fatsz32
        total = tot16 or tot32
        self.rootsecs = (self.rootents * 32 + self.bps - 1) // self.bps
        self.fatstart = self.rsvd * self.bps
        self.rootstart = (self.rsvd + self.nfats * self.fatsz) * self.bps
        self.datastart = self.rootstart + self.rootsecs * self.bps
        datasecs = total - (self.rsvd + self.nfats * self.fatsz + self.rootsecs)
        nclus = datasecs // self.spc
        self.kind = 12 if nclus < 4085 else 16 if nclus < 65525 else 32
        self.rootclus = struct.unpack_from("<I", bs, 44)[0] if self.kind == 32 else None
        self.csize = self.bps * self.spc
        self.fat = self.read(self.fatstart, self.fatsz * self.bps)

    def read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def next_clus(self, c):
        if self.kind == 16:
            return struct.unpack_from("<H", self.fat, c * 2)[0]
        if self.kind == 32:
            return struct.unpack_from("<I", self.fat, c * 4)[0] & 0x0FFFFFFF
        v = struct.unpack_from("<H", self.fat, c * 3 // 2)[0]
        return v >> 4 if c & 1 else v & 0xFFF

    def eoc(self, c):
        return c >= {12: 0xFF8, 16: 0xFFF8, 32: 0x0FFFFFF8}[self.kind] or c < 2

    def chain(self, c):
        seen = set()
        while not self.eoc(c):
            if c in seen:
                raise RuntimeError("FAT loop")
            seen.add(c)
            yield c
            c = self.next_clus(c)

    def clus_data(self, c):
        return self.read(self.datastart + (c - 2) * self.csize, self.csize)

    def dir_bytes(self, clus):
        if clus is None:  # FAT12/16 fixed root directory
            return self.read(self.rootstart, self.rootsecs * self.bps)
        return b"".join(self.clus_data(c) for c in self.chain(clus))

    def entries(self, clus):
        data = self.dir_bytes(clus)
        lfn = {}
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            attr = e[11]
            if attr == 0x0F:
                seq = e[0] & 0x1F
                part = e[1:11] + e[14:26] + e[28:32]
                lfn[seq] = part.decode("utf-16-le", "replace")
                continue
            if attr & 0x08:  # volume label
                lfn = {}
                continue
            if lfn:
                name = "".join(lfn[k] for k in sorted(lfn)).split("\x00")[0].rstrip("￿")
            else:
                base = e[0:8].decode("ascii", "replace").rstrip()
                ext = e[8:11].decode("ascii", "replace").rstrip()
                if e[12] & 0x08:
                    base = base.lower()
                if e[12] & 0x10:
                    ext = ext.lower()
                name = base + ("." + ext if ext else "")
            lfn = {}
            if name in (".", ".."):
                continue
            hi, = struct.unpack_from("<H", e, 20)
            lo, = struct.unpack_from("<H", e, 26)
            size, = struct.unpack_from("<I", e, 28)
            yield name, bool(attr & 0x10), (hi << 16) | lo, size

    def lookup(self, path):
        clus, isdir, size = self.rootclus, True, 0
        for comp in [p for p in path.split("/") if p]:
            if not isdir:
                raise FileNotFoundError(path)
            for name, d, c, s in self.entries(clus):
                if name.lower() == comp.lower():
                    clus, isdir, size = c, d, s
                    break
            else:
                raise FileNotFoundError(path)
        return clus, isdir, size

    def read_file(self, path):
        clus, isdir, size = self.lookup(path)
        if isdir:
            raise IsADirectoryError(path)
        out = bytearray()
        for c in self.chain(clus):
            out += self.clus_data(c)
            if len(out) >= size:
                break
        if len(out) < size:
            raise RuntimeError("short file " + path)
        return bytes(out[:size])

    def walk(self, path="", recursive=False):
        clus, isdir, _ = self.lookup(path)
        for name, d, c, s in sorted(self.entries(clus)):
            full = (path.rstrip("/") + "/" + name) if path else name
            yield full, d, s
            if d and recursive:
                yield from self.walk(full, True)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    fat = Fat(argv[1])
    if argv[2] == "ls":
        rec = "-r" in argv[3:]
        rest = [a for a in argv[3:] if a != "-r"]
        for full, d, s in fat.walk(rest[0] if rest else "", rec):
            print(("d " if d else "f ") + f"{s:10d} {full}")
        return 0
    if argv[2] == "get":
        data = fat.read_file(argv[3])
        with open(argv[4], "wb") as o:
            o.write(data)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
