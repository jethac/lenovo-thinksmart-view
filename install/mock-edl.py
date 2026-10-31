#!/usr/bin/env python3
"""Stand-in for bkerler/edl, backed by a disk image file, for rehearsing install.sh.

Implements the subset of edl.py that install.sh uses, with the same command syntax and the
same kind of output (Sahara identity on the first call of a session, the firehose storage
report, the GPT listing):

  printgpt | rs <start> <sectors> <file> | ws <start> <file> | reset --resetmode=<mode>
  (plus r/w <partition> <file>, which resolve names through the primary GPT, as edl does)

Environment:
  MOCK_EDL_DISK    the disk image (required)
  MOCK_EDL_STATE   directory for the session marker and the operation log (default: next to disk)
  MOCK_EDL_HWID, MOCK_EDL_PKHASH, MOCK_EDL_CHIPSERIAL, MOCK_EDL_EMMCSERIAL
                   identity printed in the Sahara/firehose output (defaults: the CD-18781Y values)
  MOCK_EDL_FAIL    one-shot fault: "ws:<lba>" fails a write to that start sector before writing;
                   "ws:<lba>:torn" writes the first half, then fails (a cable pulled mid-write);
                   "ws:<lba>:torn=<n>" writes only the first n sectors, then fails.
                   The fault fires once; MOCK_EDL_STATE/fault.fired records that it has.

Every call appends "<cmd> <start> <sectors>" to MOCK_EDL_STATE/ops.log, which rehearse.sh uses
to estimate the time on real hardware.
"""
import os
import struct
import sys
import uuid
import zlib

SECTOR = 512
DISK = os.environ.get("MOCK_EDL_DISK")
STATE = os.environ.get("MOCK_EDL_STATE") or (os.path.dirname(os.path.abspath(DISK or ".")) + "/mock-edl-state")
HWID = os.environ.get("MOCK_EDL_HWID", "0x000660e160008000")
PKHASH = os.environ.get("MOCK_EDL_PKHASH", "0xb9eca30dfea4693497b6ac7eec81d006967281e259eb9ac239f9ce6dabb70c14")
CHIPSERIAL = os.environ.get("MOCK_EDL_CHIPSERIAL", "0x00000000")
EMMCSERIAL = os.environ.get("MOCK_EDL_EMMCSERIAL", "1234567890")


def out(s):
    print(s, flush=True)


def fail(msg):
    out(f"firehose - [LIB]: {msg}")
    sys.exit(1)


def total_sectors():
    return os.path.getsize(DISK) // SECTOR


def oplog(*a):
    with open(os.path.join(STATE, "ops.log"), "a") as f:
        f.write(" ".join(str(x) for x in a) + "\n")


def connect():
    os.makedirs(STATE, exist_ok=True)
    out("Qualcomm Sahara / Firehose Client V3.62 (c) B.Kerler 2018-2025. [rehearsal mock]")
    out("main - Trying with no loader given ...")
    out("main - Waiting for the device")
    out("main - Device detected :)")
    marker = os.path.join(STATE, "session")
    if not os.path.exists(marker):
        out("main - Mode detected: sahara")
        out("sahara - ")
        out("Version 0x2")
        out("------------------------")
        out(f"HWID:              {HWID} (MSM_ID:0x000660e1,OEM_ID:0x6000,MODEL_ID:0x8000)")
        out('CPU detected:      "APQ8053"')
        out(f"PK_HASH:           {PKHASH}")
        out(f"Serial:            {CHIPSERIAL}")
        out("")
        out("sahara - Detected loader: /mock/Loaders/lenovo_motorola/000660e160008000_b9eca30dfea46934_fhprg_peek.bin")
        out("sahara - Loader successfully uploaded.")
        open(marker, "w").close()
        oplog("connect sahara")
    else:
        out("main - Mode detected: firehose")
        oplog("connect firehose")
    out("main - Trying to connect to firehose loader ...")
    out("firehose - TargetName=MSM8953")
    out("firehose - MemoryName=eMMC")
    out("firehose - Storage report:")
    out(f"firehose - total_blocks:{total_sectors()}")
    out("firehose - block_size:512")
    out(f"firehose - serial_num:{EMMCSERIAL}")
    out("firehose - mem_type:eMMC")
    out("firehose - prod_name:8GTF4R")


def read_gpt():
    with open(DISK, "rb") as f:
        f.seek(SECTOR)
        h = f.read(SECTOR)
        if h[:8] != b"EFI PART":
            return None
        n, esz, crc = struct.unpack("<III", h[80:92])
        hcrc = struct.unpack("<I", h[16:20])[0]
        chk = bytearray(h[:92])
        chk[16:20] = b"\0\0\0\0"
        if zlib.crc32(chk) & 0xFFFFFFFF != hcrc:
            return None
        elba = struct.unpack("<Q", h[72:80])[0]
        f.seek(elba * SECTOR)
        area = f.read(n * esz)
        if zlib.crc32(area) & 0xFFFFFFFF != crc:
            return None
    parts = []
    for i in range(n):
        e = area[i * esz:(i + 1) * esz]
        if e[:16] == bytes(16):
            continue
        first, last, attrs = struct.unpack("<QQQ", e[32:56])
        parts.append({"name": e[56:128].decode("utf-16le").rstrip("\0"), "start": first,
                      "size": last - first + 1, "attrs": attrs, "uuid": str(uuid.UUID(bytes_le=e[16:32])),
                      "type": str(uuid.UUID(bytes_le=e[0:16]))})
    return parts


def rs(start, count, path):
    start, count = int(start), int(count)
    if start < 0 or count <= 0 or start + count > total_sectors():
        fail(f"Error: read beyond the end of the disk ({start}+{count})")
    oplog("rs", start, count)
    with open(DISK, "rb") as f, open(path, "wb") as o:
        f.seek(start * SECTOR)
        left = count * SECTOR
        while left:
            c = f.read(min(4 << 20, left))
            left -= len(c)
            if c.count(0) == len(c):
                o.seek(len(c), 1)          # keep zero runs sparse on the laptop
            else:
                o.write(c)
        o.truncate(count * SECTOR)
    out(f"Dumped sector {start} with sector count {count} as {path}.")


def ws(start, path):
    start = int(start)
    data_len = os.path.getsize(path)
    count = -(-data_len // SECTOR)
    if start < 0 or start + count > total_sectors():
        fail(f"Error: write beyond the end of the disk ({start}+{count})")
    fault = os.environ.get("MOCK_EDL_FAIL", "")
    fired = os.path.join(STATE, "fault.fired")
    torn = None
    if fault and not os.path.exists(fired):
        bits = fault.split(":")
        if bits[0] == "ws" and int(bits[1]) == start:
            open(fired, "w").close()
            if len(bits) > 2 and bits[2].startswith("torn"):
                torn = int(bits[2].split("=")[1]) if "=" in bits[2] else count // 2
            else:
                oplog("ws-failed", start, count)
                fail(f"Error on writing {path} to sector {start} (injected fault)")
    limit = torn * SECTOR if torn is not None else count * SECTOR
    oplog("ws-torn" if torn is not None else "ws", start, count)
    with open(path, "rb") as i, open(DISK, "r+b") as f:
        f.seek(start * SECTOR)
        done = 0
        while done < limit:
            c = i.read(min(4 << 20, limit - done))
            if not c:
                c = bytes(min(4 << 20, limit - done))
            if len(c) % SECTOR and done + len(c) >= data_len:
                c += bytes(SECTOR - len(c) % SECTOR)      # edl pads the last sector
            f.write(c)
            done += len(c)
        f.flush()
        os.fsync(f.fileno())
    if torn is not None:
        fail(f"Error on writing {path} to sector {start} (injected fault: cable pulled half way)")
    out(f"Wrote {path} to sector {start}.")


def printgpt():
    parts = read_gpt()
    if parts is None:
        fail("Error: Couldn't detect partition header.")
    oplog("printgpt")
    out("\nParsing Lun 0:\n\nGPT Table:\n-------------")
    for p in parts:
        out(f"{p['name'] + ':':<21}Offset 0x{p['start'] * SECTOR:016x}, Length 0x{p['size'] * SECTOR:016x}, "
            f"Flags 0x{p['attrs']:016x}, UUID {p['uuid']}, Type 0x{p['type'][:8]}, Active False")
    t = total_sectors()
    out(f"\nTotal disk size:0x{t * SECTOR:016x}, sectors:0x{t:016x}")


def by_name(name):
    for p in read_gpt() or []:
        if p["name"] == name:
            return p
    fail(f"Error: Couldn't detect partition: {name}")


def main():
    if not DISK or not os.path.exists(DISK):
        print("mock-edl: MOCK_EDL_DISK is not set or missing", file=sys.stderr)
        sys.exit(2)
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[1:] if a.startswith("--"))
    if not args:
        fail("no command")
    connect()
    cmd = args[0]
    if cmd == "printgpt":
        printgpt()
    elif cmd == "rs":
        rs(*args[1:4])
    elif cmd == "ws":
        ws(*args[1:3])
    elif cmd == "r":
        p = by_name(args[1])
        rs(p["start"], p["size"], args[2])
    elif cmd == "w":
        p = by_name(args[1])
        if os.path.getsize(args[2]) > p["size"] * SECTOR:
            fail("Error: file larger than the partition")
        ws(p["start"], args[2])
    elif cmd == "reset":
        mode = opts.get("resetmode")
        if not mode:
            fail("Argument --resetmode required.")
        oplog("reset", mode)
        try:
            os.remove(os.path.join(STATE, "session"))
        except FileNotFoundError:
            pass
        out("Reset succeeded.")
    else:
        fail(f"mock does not implement '{cmd}'")


if __name__ == "__main__":
    main()
