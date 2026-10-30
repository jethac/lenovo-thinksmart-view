#!/usr/bin/env python3
"""Turn a disk image partitioned by sfdisk into stock-style GPT blobs.

Lenovo's GPT (backup-20261029/gpt_primary.bin, gpt_backup.bin) differs from
what sfdisk writes in two places that do not matter to Linux but are kept here
so the device only ever sees the stock structure:
  - the protective MBR covers 0xFFFFFFFF sectors (sfdisk: disk size - 1);
  - the backup entry array starts at last-lba + 1 = 15269855, 32 sectors
    reserved, instead of right below the backup header.

Writes:
  OUT/primary.bin  LBA 0..33   (34 sectors: stock PMBR, header, entry area)
  OUT/backup.bin   LBA 15269855..15269887 (33 sectors: entry area, header)

Usage:
  make-gpt-blobs.py --pmbr STOCK_PRIMARY.bin IMAGE OUTDIR
  make-gpt-blobs.py --selftest STOCK_PRIMARY.bin STOCK_BACKUP.bin
"""
import os
import struct
import sys
import zlib

SECTOR = 512
HDR = struct.Struct("<8sIIIIQQQQ16sQIII")


def unpack(buf):
    return list(HDR.unpack(buf[:HDR.size]))


def pack(f):
    f = list(f)
    f[3] = 0
    raw = HDR.pack(*f)
    f[3] = zlib.crc32(raw) & 0xFFFFFFFF
    return HDR.pack(*f) + b"\0" * (SECTOR - HDR.size)


def check_header(h, entries):
    f = unpack(h)
    assert f[0] == b"EFI PART" and f[2] == 92, "not a GPT header"
    g = list(f)
    g[3] = 0
    assert zlib.crc32(HDR.pack(*g)) & 0xFFFFFFFF == f[3], "header CRC"
    n, esz = f[11], f[12]
    assert zlib.crc32(entries[: n * esz]) & 0xFFFFFFFF == f[13], "entries CRC"
    return f


def backup_from_primary(primary):
    """primary = 34 sectors starting at LBA 0. Returns the 33-sector backup."""
    hdr = primary[SECTOR:2 * SECTOR]
    area = primary[2 * SECTOR:34 * SECTOR]          # 32 sectors of entries
    f = check_header(hdr, area)
    cur, alt, last = f[5], f[6], f[8]
    assert cur == 1 and f[10] == 2
    b = list(f)
    b[5], b[6] = alt, cur                          # MyLBA, AlternateLBA
    b[10] = last + 1                               # PartitionEntryLBA
    assert b[10] + 32 == alt, "entry area must end right below the backup header"
    return area + pack(b)


def selftest(stock_primary, stock_backup):
    p = open(stock_primary, "rb").read()
    b = open(stock_backup, "rb").read()
    assert len(p) == 34 * SECTOR and len(b) == 33 * SECTOR
    assert backup_from_primary(p) == b, "method does not reproduce the stock backup"
    print("selftest: stock backup reproduced byte for byte from stock primary")


def main():
    if sys.argv[1] == "--selftest":
        selftest(sys.argv[2], sys.argv[3])
        return
    assert sys.argv[1] == "--pmbr"
    pmbr = open(sys.argv[2], "rb").read()[:SECTOR]
    img, out = sys.argv[3], sys.argv[4]
    with open(img, "rb") as fh:
        raw = fh.read(34 * SECTOR)
    primary = pmbr + raw[SECTOR:]
    # sfdisk leaves the unused part of the 32-sector entry area zeroed; check.
    f = unpack(raw[SECTOR:])
    used = f[11] * f[12]
    assert raw[2 * SECTOR + used:] == b"\0" * (32 * SECTOR - used)
    backup = backup_from_primary(primary)
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "primary.bin"), "wb").write(primary)
    open(os.path.join(out, "backup.bin"), "wb").write(backup)
    print(f"wrote {out}/primary.bin (LBA 0, 34 sectors), "
          f"{out}/backup.bin (LBA {f[8] + 1}, 33 sectors)")


if __name__ == "__main__":
    main()
