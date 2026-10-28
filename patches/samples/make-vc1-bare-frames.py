#!/usr/bin/env python3
#
# Generates two Matroska files with the same VC-1 Advanced frames:
#   samples/vc1-320x240-bare-frames.mkv   frames stored the way ASF stores them
#       (WVC1): no frame start code at the start of a packet, and the sequence
#       header and entry points only in the extradata
#   samples/vc1-320x240-start-codes.mkv   the elementary stream's layout, as in
#       Blu-ray VC-1: start codes, and the header in-band before the keyframe
# Both have the header in the extradata, after one byte that stands in for
# ASF's leading byte.
#
# ffmpeg has no VC-1 encoder, and its muxers keep the start codes, so the
# frames come from SA00050.vc1 in the FATE suite (SMPTE VC-1 conformance,
# 320x240, 25 fps, 30 frames, I and P only, so coded order is display order)
# and the Matroska file is written by hand. The source has no slice start
# codes: vc1dec can't split slices in a frame without a start code, so a
# multi-slice source would not decode in software from this layout.
#
# Usage: make-vc1-bare-frames.py /path/to/fate-suite/vc1/SA00050.vc1

import os
import struct
import sys

SRC = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))

W, H = 320, 240
FPS = 25


def ebml_size(n):
    for length in range(1, 9):
        if n < (1 << (7 * length)) - 1:
            return ((1 << (7 * length)) | n).to_bytes(length, "big")
    raise ValueError(n)


def element(eid, payload):
    return eid.to_bytes((eid.bit_length() + 7) // 8, "big") + ebml_size(len(payload)) + payload


def uint(eid, value):
    return element(eid, value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big"))


def units(data):
    starts = [i for i in range(len(data) - 3) if data[i:i + 3] == b"\x00\x00\x01"]
    return [(data[s + 3], data[s:e]) for s, e in zip(starts, starts[1:] + [len(data)])]


def frames(data):
    """Returns the header and each frame as (bare, with start codes)."""
    header, out, cur = b"", [], None
    for code, unit in units(data):
        if code == 0x0D:
            cur = [bytearray(unit[4:]), bytearray(unit if out else header + unit)]
            out.append(cur)
        elif code in (0x0F, 0x0E):
            if out:
                sys.exit("sequence header or entry point after the first frame; extend this script")
            header += unit
        elif code == 0x0B:
            sys.exit("slice start code; vc1dec can't decode this layout")
        elif cur is not None:
            cur[0] += unit
            cur[1] += unit
    return header, [(bytes(b), bytes(s)) for b, s in out]


def write(name, coded):
    blocks = b"".join(
        element(0xA3, b"\x81" + struct.pack(">hB", i * frame_ms, 0x80 if i == 0 else 0x00) + f)
        for i, f in enumerate(coded))
    segment = element(0x18538067, info + element(0x1654AE6B, track)
                      + element(0x1F43B675, uint(0xE7, 0) + blocks))
    out = os.path.join(HERE, name)
    with open(out, "wb") as f:
        f.write(doc + segment)
    print(f"{out}: {len(coded)} frames, {len(header)}-byte header")


header, coded = frames(open(SRC, "rb").read())

extradata = b"\x00" + header
bih = struct.pack("<IiiHHIIiiII", 40 + len(extradata), W, H, 1, 24,
                  int.from_bytes(b"WVC1", "little"), 0, 0, 0, 0, 0) + extradata

frame_ms = 1000 // FPS
doc = element(0x1A45DFA3, uint(0x4286, 1) + uint(0x42F7, 1) + uint(0x42F2, 4) + uint(0x42F3, 8)
              + element(0x4282, b"matroska") + uint(0x4287, 4) + uint(0x4285, 2))
info = element(0x1549A966, uint(0x2AD7B1, 1000000) + element(0x4D80, b"make-vc1-bare-frames")
               + element(0x5741, b"make-vc1-bare-frames"))
track = element(0xAE, uint(0xD7, 1) + uint(0x73C5, 1) + uint(0x83, 1) + uint(0x9C, 0)
                + element(0x86, b"V_MS/VFW/FOURCC") + element(0x63A2, bih)
                + uint(0x23E383, 1000000000 // FPS)
                + element(0xE0, uint(0xB0, W) + uint(0xBA, H)))

write("vc1-320x240-bare-frames.mkv", [b for b, _ in coded])
write("vc1-320x240-start-codes.mkv", [s for _, s in coded])
