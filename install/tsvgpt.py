#!/usr/bin/env python3
"""GPT and backup helpers for install.sh (ThinkSmart View CD-18781Y).

Works on raw GPT copies as read over EDL:
  primary = 34 sectors from LBA 0 (protective MBR, header, 32 sectors of entries)
  backup  = 33 sectors from LBA total-33 (32 sectors of entries, header)

Commands (all output is key=value or TSV on stdout; errors exit 1):
  classify PRIMARY BACKUP TOTAL      state of the table on disk: stock, stageb, half, unknown
  table GPTCOPY [primary|backup]     TSV: num name start size type uuid attrs
  uuids-kept STOCK_PRIMARY NEW_PRIMARY
                                     every entry of NEW has the UUID, type and attrs of the
                                     stock entry of the same name; same disk GUID
  check-lk2nd IMG MAXBYTES           Android boot image, no QCDT, BootSignature, SEANDROIDENFORCE
  check-image IMG MAXSECTORS         nested MBR of the system image: p1 ext2 boot, p2 root
  devinfo-serial FILE                serial number stored in devinfo (sector 0)
  parse-edl LOGFILE                  HWID, PK hash, mode, storage report from edl output
  backup-plan PRIMARY SKIP           regions to read: start count (SKIP: comma list of names)
  slice PRIMARY REGION START OUTDIR SKIP
                                     cut a region dump into partitions/<name>.img.zst and
                                     gaps; append SHA256SUMS, partitions.tsv, gaps.tsv
  verify-backup DIR                  decompress everything and check SHA256SUMS
  restore-plan DIR SYSTEM_START      TSV: kind start count file sha256 label
"""
import hashlib
import importlib.util
import os
import re
import struct
import subprocess
import sys
import uuid
import zlib

SECTOR = 512
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HDR = struct.Struct("<8sIIIIQQQQ16sQIII")
ENTRY = struct.Struct("<16s16sQQQ72s")

# The protective MBR of Lenovo's table (0xFFFFFFFF sectors). Identical on this unit and in the
# factory packages; only bytes 440-511 are non-zero.
PMBR = bytes(440) + bytes.fromhex(
    "00000000000000000100eeffffff01000000ffffffff" + "00" * 48 + "55aa")
assert len(PMBR) == SECTOR

FIRST_LBA = 34
N_ENTRIES = 52
ENTRY_SIZE = 128
ALIGN = 2048
TAIL = ["persist", "syscfg", "mcfg", "apdp", "msadp"]
SYSTEM_START = 923648


def die(msg):
    print(f"tsvgpt: {msg}", file=sys.stderr)
    sys.exit(1)


def load_blobs_module():
    path = os.path.join(ROOT, "streams", "stage-b", "make-gpt-blobs.py")
    spec = importlib.util.spec_from_file_location("make_gpt_blobs", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- parsing

def guid(b):
    return str(uuid.UUID(bytes_le=b)).upper()


def parse_copy(hdr_sector, area):
    """Return dict with header fields and entries, or {'valid': False, 'why': ...}."""
    f = HDR.unpack(hdr_sector[:HDR.size])
    sig, rev, hsize, hcrc = f[0], f[1], f[2], f[3]
    if sig != b"EFI PART":
        return {"valid": False, "why": "no GPT signature"}
    if hsize != 92:
        return {"valid": False, "why": f"header size {hsize}"}
    g = list(f)
    g[3] = 0
    if zlib.crc32(HDR.pack(*g)) & 0xFFFFFFFF != hcrc:
        return {"valid": False, "why": "header CRC"}
    n, esz = f[11], f[12]
    if esz != ENTRY_SIZE or n * esz > len(area):
        return {"valid": False, "why": f"entries {n} x {esz}"}
    if zlib.crc32(area[:n * esz]) & 0xFFFFFFFF != f[13]:
        return {"valid": False, "why": "entries CRC"}
    entries = []
    for i in range(n):
        raw = area[i * esz:(i + 1) * esz]
        t, u, first, last, attrs, name = ENTRY.unpack(raw[:ENTRY.size])
        if t == bytes(16):
            if raw != bytes(esz):
                return {"valid": False, "why": f"entry {i + 1} unused but not zero"}
            entries.append(None)
            continue
        entries.append({
            "num": i + 1, "type": guid(t), "uuid": guid(u), "start": first,
            "size": last - first + 1, "attrs": attrs,
            "name": name.decode("utf-16le").rstrip("\0"),
        })
    return {"valid": True, "rev": rev, "my": f[5], "alt": f[6], "first": f[7], "last": f[8],
            "disk": guid(f[9]), "entries_lba": f[10], "n": n, "esz": esz, "entries": entries,
            "area": area[:n * esz]}


def read_primary(path):
    d = open(path, "rb").read()
    if len(d) != 34 * SECTOR:
        die(f"{path}: {len(d)} bytes, expected {34 * SECTOR}")
    c = parse_copy(d[SECTOR:2 * SECTOR], d[2 * SECTOR:])
    c["pmbr_ok"] = d[:SECTOR] == PMBR
    return c, d


def read_backup(path):
    d = open(path, "rb").read()
    if len(d) != 33 * SECTOR:
        die(f"{path}: {len(d)} bytes, expected {33 * SECTOR}")
    return parse_copy(d[32 * SECTOR:], d[:32 * SECTOR]), d


# ---------------------------------------------------------------- structures

def stock_structure(last_lba):
    rows = []
    for line in open(os.path.join(HERE, "stock-gpt.layout")):
        if line.startswith("#") or not line.strip():
            continue
        num, name, start, size, typ, attrs = line.split()
        start = int(start)
        size = last_lba - start + 1 if size == "REST" else int(size)
        rows.append((int(num), name, start, size, typ, int(attrs, 16)))
    return rows


def stageb_structure(last_lba):
    """The make-layout.py transformation, on the structure only (no UUIDs)."""
    stock = stock_structure(last_lba)
    by_name = {r[1]: r for r in stock}
    end = (last_lba + 1) // ALIGN * ALIGN
    slots = [(n, -(-by_name[n][3] // ALIGN) * ALIGN) for n in TAIL]
    tail_start = end - sum(s for _, s in slots)
    rows = [r for r in stock if r[0] <= 23]
    s = stock[23]
    assert s[1] == "system" and s[2] == SYSTEM_START
    rows.append((24, "system", s[2], tail_start - s[2], s[4], s[5]))
    pos = tail_start
    for i, (n, slot) in enumerate(slots):
        r = by_name[n]
        rows.append((25 + i, n, pos, r[3], r[4], r[5]))
        pos += slot
    return rows


def structure_of(c):
    return [(e["num"], e["name"], e["start"], e["size"], e["type"], e["attrs"])
            for e in c["entries"] if e is not None]


def kind_of(c, total, which):
    """stock / stageb / unknown / invalid for one GPT copy."""
    if not c["valid"]:
        return "invalid", c["why"]
    last = total - 34
    exp_my, exp_alt, exp_elba = (1, total - 1, 2) if which == "primary" else (total - 1, 1, last + 1)
    if (c["my"], c["alt"], c["entries_lba"]) != (exp_my, exp_alt, exp_elba):
        return "unknown", f"header LBAs {c['my']}/{c['alt']}/{c['entries_lba']}"
    if (c["rev"], c["first"], c["last"], c["n"], c["esz"]) != (0x10000, FIRST_LBA, last, N_ENTRIES, ENTRY_SIZE):
        return "unknown", "header geometry"
    if which == "primary" and not c.get("pmbr_ok"):
        return "unknown", "protective MBR is not Lenovo's"
    nums = [e["num"] for e in c["entries"] if e is not None]
    if nums != list(range(1, len(nums) + 1)):
        return "unknown", "entries not contiguous from 1"
    st = structure_of(c)
    if st == stock_structure(last):
        return "stock", ""
    if st == stageb_structure(last):
        return "stageb", ""
    return "unknown", "entries match neither the stock nor the stage-B structure"


def classify(primary, backup, total):
    total = int(total)
    p, pd = read_primary(primary)
    b, bd = read_backup(backup)
    pk, pwhy = kind_of(p, total, "primary")
    bk, bwhy = kind_of(b, total, "backup")
    consistent = False
    if p["valid"] and b["valid"]:
        try:
            consistent = load_blobs_module().backup_from_primary(pd) == bd
        except AssertionError:
            consistent = False
    if pk == bk and pk in ("stock", "stageb") and consistent:
        state = pk
    elif pk != bk and {pk, bk} <= {"stock", "stageb", "invalid"}:
        state = "half"              # one copy rewritten, or one copy torn
    else:
        state = "unknown"
    print(f"state={state}")
    print(f"primary={pk}")
    print(f"primary_why={pwhy}")
    print(f"backup={bk}")
    print(f"backup_why={bwhy}")
    print(f"consistent={'yes' if consistent else 'no'}")
    for c, tag in ((p, "primary"), (b, "backup")):
        if c["valid"]:
            print(f"{tag}_disk_guid={c['disk']}")
            print(f"{tag}_entries={sum(1 for e in c['entries'] if e is not None)}")


def table(path, which="primary"):
    c, _ = read_primary(path) if which == "primary" else read_backup(path)
    if not c["valid"]:
        die(f"{path}: invalid GPT ({c['why']})")
    for e in c["entries"]:
        if e is not None:
            print(f"{e['num']}\t{e['name']}\t{e['start']}\t{e['size']}\t{e['type']}\t{e['uuid']}\t0x{e['attrs']:016x}")


def uuids_kept(stock_path, new_path):
    s, _ = read_primary(stock_path)
    n, _ = read_primary(new_path)
    if not (s["valid"] and n["valid"]):
        die("invalid GPT")
    if s["disk"] != n["disk"]:
        die("disk GUID differs")
    by = {e["name"]: e for e in s["entries"] if e}
    for e in n["entries"]:
        if e is None:
            continue
        o = by.get(e["name"])
        if o is None or (o["uuid"], o["type"], o["attrs"]) != (e["uuid"], e["type"], e["attrs"]):
            die(f"{e['name']}: UUID/type/attrs not kept from the stock entry")
        if e["name"] != "system" and o["size"] != e["size"]:
            die(f"{e['name']}: size changed")
    print(f"uuids-kept: {sum(1 for e in n['entries'] if e)} entries keep this unit's UUID, type and attributes")


# ---------------------------------------------------------------- images

def check_lk2nd(path, maxbytes):
    d = open(path, "rb").read()
    if d[:8] != b"ANDROID!":
        die("lk2nd: not an Android boot image")
    ks, _, rs, _, ss, _, _, ps = struct.unpack("<8I", d[8:40])
    dt = struct.unpack("<I", d[40:44])[0]
    if dt != 0:
        die("lk2nd: header carries a QCDT (dt_size != 0); build with LK2ND_QCDTBS=\"\"")
    pg = lambda n: (n + ps - 1) // ps * ps
    end = ps + pg(ks) + pg(rs) + pg(ss)
    if d[end:end + 1] != b"\x30":
        die("lk2nd: no BootSignature after the payload; build with SIGN_BOOTIMG=1")
    if not d.rstrip(b"\0").endswith(b"SEANDROIDENFORCE"):
        die("lk2nd: SEANDROIDENFORCE trailer missing")
    if len(d) > int(maxbytes):
        die(f"lk2nd: {len(d)} bytes does not fit boot ({maxbytes})")
    print(f"lk2nd: boot image, page {ps}, signed (BootSignature at {end}), {len(d)} bytes")


def check_image(path, maxsectors):
    size = os.path.getsize(path)
    if size % SECTOR:
        die("image size is not a whole number of sectors")
    with open(path, "rb") as f:
        mbr = f.read(SECTOR)
        if mbr[510:] != b"\x55\xaa":
            die("image: no MBR signature")
        parts = []
        for i in range(4):
            e = mbr[446 + 16 * i:462 + 16 * i]
            boot, typ = e[0], e[4]
            start, count = struct.unpack("<II", e[8:16])
            parts.append((boot, typ, start, count))
        b1, t1, s1, c1 = parts[0]
        _, t2, s2, c2 = parts[1]
        if not (b1 == 0x80 and t1 == 0x83 and t2 == 0x83):
            die("image: expected p1 bootable Linux, p2 Linux")
        if s2 + c2 > size // SECTOR or s1 + c1 > s2:
            die("image: MBR partitions outside the image")
        for s, label in ((s1, "tsv-boot"), (s2, "tsv-root")):
            f.seek(s * SECTOR + 1024)
            sb = f.read(1024)
            if sb[56:58] != b"\x53\xef":
                die(f"image: no ext superblock at sector {s}")
            vol = sb[120:136].rstrip(b"\0").decode()
            if vol != label:
                die(f"image: filesystem at {s} is '{vol}', expected {label}")
    if size // SECTOR > int(maxsectors):
        die(f"image: {size // SECTOR} sectors does not fit system ({maxsectors})")
    print(f"sectors={size // SECTOR}")
    print(f"p1_start={s1}")
    print(f"p2_start={s2}")
    print(f"p2_size={c2}")


def devinfo_serial(path):
    d = open(path, "rb").read(SECTOR)
    if d[:13] != b"ANDROID-BOOT!":
        die("devinfo: no ANDROID-BOOT! magic")
    raw = d[228:260].split(b"\0")[0]
    s = raw.decode("ascii", "replace")
    if not re.fullmatch(r"[A-Z0-9]{6,20}", s):
        die("devinfo: no serial number at offset 228")
    print(s)


def parse_edl(path):
    t = open(path, "rb").read().decode("utf-8", "replace")
    t = re.sub(r"\x1b\[[0-9;]*m", "", t).replace("\r", "\n")
    pats = {
        "hwid": r"HWID:\s*(0x[0-9a-fA-F]+)",
        "pk_hash": r"PK_HASH:\s*(0x[0-9a-fA-F]+)",
        "chip_serial": r"^Serial:\s*(0x[0-9a-fA-F]+)",
        "mode": r"Mode detected:\s*(\w+)",
        "loader": r"Detected loader:\s*(\S+)",
        "total_blocks": r"total_blocks:\s*(\d+)",
        "block_size": r"block_size:\s*(\d+)",
        "emmc_serial": r"serial_num:\s*(\d+)",
        "prod_name": r"prod_name:\s*(\S+)",
        "memory": r"MemoryName=(\S+)",
    }
    for k, p in pats.items():
        m = re.search(p, t, re.M)
        v = m.group(1) if m else ""
        if k == "loader":
            v = os.path.basename(v)
        print(f"{k}={v.lower() if k in ('hwid', 'pk_hash', 'chip_serial') else v}")


# ---------------------------------------------------------------- backup

def partitions_of(path):
    c, _ = read_primary(path)
    if not c["valid"]:
        die(f"{path}: invalid primary GPT")
    return [e for e in c["entries"] if e is not None]


def backup_plan(primary, skip, merge=262144):
    skip = set(filter(None, skip.split(",")))
    parts = sorted((e for e in partitions_of(primary) if e["name"] not in skip), key=lambda e: e["start"])
    regions = []
    for e in parts:
        s, n = e["start"], e["size"]
        if regions and s - (regions[-1][0] + regions[-1][1]) <= merge and s >= regions[-1][0] + regions[-1][1]:
            regions[-1][1] = s + n - regions[-1][0]
        else:
            regions.append([s, n])
    for s, n in regions:
        print(f"{s}\t{n}")


def zstd_write(path, chunks):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    p = subprocess.Popen(["zstd", "-q", "-f", "-3", "-T0", "-o", path], stdin=subprocess.PIPE)
    h = hashlib.sha256()
    for c in chunks:
        h.update(c)
        p.stdin.write(c)
    p.stdin.close()
    if p.wait() != 0:
        die(f"zstd failed for {path}")
    return h.hexdigest()


def read_chunks(f, offset, length, bs=4 << 20):
    f.seek(offset)
    left = length
    while left:
        c = f.read(min(bs, left))
        if not c:
            die("region dump shorter than expected")
        left -= len(c)
        yield c


def slice_region(primary, region, start, outdir, skip):
    start = int(start)
    skip = set(filter(None, skip.split(",")))
    size = os.path.getsize(region) // SECTOR
    end = start + size
    parts = sorted((e for e in partitions_of(primary) if e["name"] not in skip), key=lambda e: e["start"])
    inside = [e for e in parts if e["start"] >= start and e["start"] + e["size"] <= end]
    for e in parts:
        if e not in inside and e["start"] < end and e["start"] + e["size"] > start:
            die(f"{e['name']} is only partly inside region {start}+{size}")
    sums = open(os.path.join(outdir, "SHA256SUMS"), "a")
    ptsv = open(os.path.join(outdir, "partitions.tsv"), "a")
    gtsv = open(os.path.join(outdir, "gaps.tsv"), "a")
    pos = start
    with open(region, "rb") as f:
        def gap(gs, ge):
            if ge <= gs:
                return
            chunks = list(read_chunks(f, (gs - start) * SECTOR, (ge - gs) * SECTOR))
            if all(c.count(0) == len(c) for c in chunks):
                h = hashlib.sha256()
                for c in chunks:
                    h.update(c)
                gtsv.write(f"{gs}\t{ge - gs}\tzero\t-\t{h.hexdigest()}\n")
            else:
                rel = f"gaps/{gs}.img"
                h = zstd_write(os.path.join(outdir, rel + ".zst"), chunks)
                gtsv.write(f"{gs}\t{ge - gs}\tdata\t{rel}.zst\t{h}\n")
                sums.write(f"{h}  {rel}\n")
        for e in inside:
            gap(pos, e["start"])
            rel = f"partitions/{e['name']}.img"
            h = zstd_write(os.path.join(outdir, rel + ".zst"),
                           read_chunks(f, (e["start"] - start) * SECTOR, e["size"] * SECTOR))
            sums.write(f"{h}  {rel}\n")
            ptsv.write(f"{e['num']}\t{e['name']}\t{e['start']}\t{e['size']}\t{e['type']}\t{e['uuid']}\t"
                       f"0x{e['attrs']:016x}\t{rel}.zst\n")
            print(f"  {e['name']:<12} {e['start']:>9} +{e['size']:>9}  sha256 {h[:16]}...")
            pos = e["start"] + e["size"]
        gap(pos, end)


def verify_backup(d):
    n = 0
    for line in open(os.path.join(d, "SHA256SUMS")):
        want, rel = line.split()
        p = os.path.join(d, rel)
        h = hashlib.sha256()
        if os.path.exists(p + ".zst"):
            proc = subprocess.Popen(["zstd", "-dc", "-q", p + ".zst"], stdout=subprocess.PIPE)
            for c in iter(lambda: proc.stdout.read(4 << 20), b""):
                h.update(c)
            if proc.wait() != 0:
                die(f"{rel}.zst: zstd failed")
        elif os.path.exists(p):
            with open(p, "rb") as f:
                for c in iter(lambda: f.read(4 << 20), b""):
                    h.update(c)
        else:
            die(f"{rel}: missing")
        if h.hexdigest() != want:
            die(f"{rel}: sha256 mismatch")
        n += 1
    print(f"verify-backup: {n} files read back from the laptop copy, all sha256 OK")


def restore_plan(d, system_start):
    system_start = int(system_start)
    items = []
    for line in open(os.path.join(d, "partitions.tsv")):
        num, name, start, size, _, _, _, rel = line.rstrip("\n").split("\t")
        start, size = int(start), int(size)
        if start >= system_start or name == "boot":
            items.append(("part", start, size, rel, name))
    if os.path.exists(os.path.join(d, "gaps.tsv")):
        for line in open(os.path.join(d, "gaps.tsv")):
            start, size, kind, rel, sha = line.rstrip("\n").split("\t")
            start, size = int(start), int(size)
            if start >= system_start:
                items.append(("gap-" + kind, start, size, rel, f"gap {start}"))
    sums = {}
    for line in open(os.path.join(d, "SHA256SUMS")):
        h, rel = line.split()
        sums[rel] = h
    gsha = {}
    if os.path.exists(os.path.join(d, "gaps.tsv")):
        for line in open(os.path.join(d, "gaps.tsv")):
            start, size, kind, rel, sha = line.rstrip("\n").split("\t")
            gsha[int(start)] = sha
    for kind, start, size, rel, label in sorted(items, key=lambda x: x[1]):
        sha = sums.get(rel[:-4], "") if kind == "part" else gsha[start]
        print(f"{kind}\t{start}\t{size}\t{rel}\t{sha}\t{label}")


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        sys.exit(2)
    cmd, args = a[0], a[1:]
    fn = {
        "classify": classify, "table": table, "uuids-kept": uuids_kept,
        "check-lk2nd": check_lk2nd, "check-image": check_image,
        "devinfo-serial": devinfo_serial, "parse-edl": parse_edl,
        "backup-plan": backup_plan, "slice": slice_region,
        "verify-backup": verify_backup, "restore-plan": restore_plan,
    }.get(cmd)
    if fn is None:
        die(f"unknown command {cmd}")
    fn(*args)


if __name__ == "__main__":
    main()
