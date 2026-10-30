#!/usr/bin/env python3
"""Pack / dump ath10k firmware-N.bin containers (the ath10k-fwencoder format).

The container is the magic "QCA-ATH10K\\0" (padded to 4 bytes) followed by
IEs: le32 id, le32 len, data padded to 4 bytes. Ids and values are from
drivers/net/wireless/ath/ath10k/hw.h and core.h (Linux 7.3).

  ath10k-fwpack.py dump FILE
  ath10k-fwpack.py pack --fw IMAGE [--otp OTP] --version STR \
      --features f1,f2 --wmi tlv --htt tlv [--timestamp N] -o OUT
"""
import argparse
import struct
import sys

MAGIC = b"QCA-ATH10K\x00"
IE = {"fw-version": 0, "timestamp": 1, "features": 2, "fw-image": 3,
      "otp-image": 4, "wmi-op-version": 5, "htt-op-version": 6,
      "fw-code-swap-image": 7}
IE_NAME = {v: k for k, v in IE.items()}
FEATURES = ["ext-wmi-mgmt-rx", "wmi-10.x", "has-wmi-mgmt-tx", "no-p2p",
            "wmi-10.2", "multi-vif-ps", "wowlan", "ignore-otp",
            "no-4addr-pad", "skip-clock-init", "raw-mode", "adaptive-cca",
            "mfp", "peer-flow-ctrl", "btcoex-param", "skip-null-func-war",
            "allows-mesh-bcast", "no-ps", "mgmt-tx-by-ref",
            "non-bmi", "single-chan-info-per-channel", "peer-fixed-rate",
            "iram-recovery"]
WMI = {"main": 1, "10.1": 2, "10.2": 3, "tlv": 4, "10.2.4": 5, "10.4": 6}
HTT = {"main": 1, "10.1": 2, "tlv": 3, "10.4": 4}


def pad4(b):
    return b + b"\x00" * (-len(b) % 4)


def ie(i, data):
    return struct.pack("<II", i, len(data)) + pad4(data)


def dump(path):
    d = open(path, "rb").read()
    if not d.startswith(MAGIC):
        sys.exit("bad magic")
    off = (len(MAGIC) + 3) & ~3
    while off + 8 <= len(d):
        i, n = struct.unpack_from("<II", d, off)
        data = d[off + 8:off + 8 + n]
        name = IE_NAME.get(i, str(i))
        if i == 0:
            val = data.decode(errors="replace")
        elif i == 2:
            bits = int.from_bytes(data, "little")
            val = ",".join(FEATURES[b] if b < len(FEATURES) else str(b)
                           for b in range(len(data) * 8) if bits >> b & 1)
        elif i in (1, 5, 6):
            val = struct.unpack("<I", data[:4])[0]
        else:
            val = f"{n} bytes"
        print(f"{name}: {val}")
        off += 8 + ((n + 3) & ~3)


def pack(a):
    out = pad4(MAGIC)
    out += ie(0, a.version.encode())
    if a.timestamp is not None:
        out += ie(1, struct.pack("<I", a.timestamp))
    bits = 0
    for f in filter(None, a.features.split(",")):
        bits |= 1 << FEATURES.index(f)
    nbytes = max(4, (bits.bit_length() + 31) // 32 * 4)
    out += ie(2, bits.to_bytes(nbytes, "little"))
    out += ie(3, open(a.fw, "rb").read())
    if a.otp:
        out += ie(4, open(a.otp, "rb").read())
    out += ie(5, struct.pack("<I", WMI[a.wmi]))
    out += ie(6, struct.pack("<I", HTT[a.htt]))
    open(a.o, "wb").write(out)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dump")
    d.add_argument("file")
    k = sub.add_parser("pack")
    k.add_argument("--fw", required=True)
    k.add_argument("--otp")
    k.add_argument("--version", required=True)
    k.add_argument("--features", default="")
    k.add_argument("--wmi", default="tlv")
    k.add_argument("--htt", default="tlv")
    k.add_argument("--timestamp", type=int)
    k.add_argument("-o", required=True)
    a = p.parse_args()
    if a.cmd == "dump":
        dump(a.file)
    else:
        pack(a)


if __name__ == "__main__":
    main()
