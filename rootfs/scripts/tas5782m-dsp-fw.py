#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build the TAS5782M DSP configuration for the ThinkSmart View CD-18781Y.

Lenovo ships the speaker tuning (EQ and excursion protection) for the
TAS5782M as a register table, tas5782m_init_sequence[], in its GPL kernel
source (sound/soc/codecs/tas5782m.h in
lenovo_cd-18781y_cd-18781y.201218.2018_opensource.tgz). The mainline
tas5782m driver loads the same table as firmware, in the format used by
the upstream tas5805m driver: a flat sequence of (register, value) byte
pairs, book and page writes included.

The driver issues the fixed start of the sequence itself (book 0 / page 0,
standby and power down, module and register reset, the settling delay),
and it controls mute. So the file holds Lenovo's table from the first
write after the reset delay (CTRL3 mute) up to, but not including, the
final "Unmute the device" block.

    tas5782m-dsp-fw.py path/to/tas5782m.h out/tas5782m_dsp_lenovo_cd-18781y.bin

The input is checked against the known hash of Lenovo's header, so the
output is always the stock tuning, byte for byte.
"""
import hashlib
import re
import sys

GPL_HEADER_SHA256 = "1be523d511022931e175a781a28485f1061b729122d0a75f20c45919fbf5a91b"
TABLE_ENTRIES = 1535

# Lenovo's table, by index:
#   0..7     page 0, book 0, standby+powerdown, reset, 4 x "page 0" (delay)
#   8..1530  mute, clocking, sample rate, DSP coefficients, register tuning
#   1531..   page 0, book 0, unmute
PREAMBLE = [(0x00, 0x00), (0x7f, 0x00), (0x02, 0x11), (0x01, 0x11),
            (0x00, 0x00), (0x00, 0x00), (0x00, 0x00), (0x00, 0x00)]
UNMUTE = [(0x00, 0x00), (0x7f, 0x00), (0x03, 0x00), (0x2a, 0x11)]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    raw = open(src, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != GPL_HEADER_SHA256:
        sys.exit(f"{src}: sha256 {digest} is not Lenovo's tas5782m.h")

    text = raw.decode("ascii")
    body = text[text.index("tas5782m_init_sequence"):]
    seq = [(int(r, 16), int(v, 16)) for r, v in
           re.findall(r"\{\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*\}", body)]
    if len(seq) != TABLE_ENTRIES:
        sys.exit(f"expected {TABLE_ENTRIES} entries, found {len(seq)}")
    if seq[:len(PREAMBLE)] != PREAMBLE or seq[-len(UNMUTE):] != UNMUTE:
        sys.exit("table does not start/end as expected")

    cfg = seq[len(PREAMBLE):-len(UNMUTE)]
    # The file must never unmute by itself: in book 0 / page 0 the only
    # CTRL3 write is the mute, and the DAC data path stays off. It ends on
    # book 0 / page 1 (analog gain); the driver returns to page 0 after it.
    book = page = 0
    for reg, val in cfg:
        if reg == 0x00:
            page = val
        elif reg == 0x7f and page == 0:
            book = val
        elif book == 0 and page == 0 and reg in (0x03, 0x2a):
            assert (reg, val) in ((0x03, 0x11), (0x2a, 0x00)), (reg, val)
    assert cfg[0] == (0x03, 0x11) and (book, page) == (0, 1)
    with open(out, "wb") as f:
        f.write(bytes(b for pair in cfg for b in pair))
    print(f"{out}: {len(cfg)} writes, sha256 "
          f"{hashlib.sha256(bytes(b for p in cfg for b in p)).hexdigest()}")


if __name__ == "__main__":
    main()
