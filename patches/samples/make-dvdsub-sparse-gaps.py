#!/usr/bin/env python3
#
# Generates samples/dvdsub-sparse-gaps-h264.mkv: synthetic smptebars video plus
# a synthetic dvd_subtitle track whose only interesting property is its timing -
# a dense run of cues, one long gap, then a few more cues. Each cue is a solid
# box; the bitmap content is irrelevant to the readrate bug.
#
# ffmpeg cannot encode dvdsub from text, so the track is written as a VobSub
# .idx/.sub pair by hand and stream-copied into Matroska.
#
# Usage: make-dvdsub-sparse-gaps.py [/path/to/ffmpeg]

import os
import struct
import subprocess
import sys
import tempfile

FFMPEG = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("FFMPEG", "ffmpeg")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dvdsub-sparse-gaps-h264.mkv")

W, H = 320, 240
DURATION = 30

# (start, duration) seconds; the 7.0 -> 22.0 gap is the one the reproducer measures
CUES = [(1.0, 1.5), (3.0, 1.5), (5.0, 1.5), (7.0, 1.5),
        (22.0, 1.5), (24.0, 1.5), (26.0, 1.5), (28.0, 1.5)]

BOX_X1, BOX_X2 = 40, 279
BOX_Y1, BOX_Y2 = 190, 221


def spu(duration, color):
    lines = BOX_Y2 - BOX_Y1 + 1
    # RLE code 0x000c: "fill the rest of the line with color c"
    line = bytes([0x00, color])
    top = line * ((lines + 1) // 2)
    bottom = line * (lines // 2)
    top_off = 4
    bottom_off = top_off + len(top)
    dcsq1 = bottom_off + len(bottom)
    dcsq2 = dcsq1 + 24

    cmds = bytearray()
    cmds += struct.pack(">HH", 0, dcsq2)
    cmds += bytes([0x03, 0x32, 0x10])  # palette: color n -> palette entry n
    cmds += bytes([0x04, 0xFF, 0xF0])  # alpha: color 0 transparent, others opaque
    cmds += bytes([0x05,
                   BOX_X1 >> 4, ((BOX_X1 & 0xF) << 4) | (BOX_X2 >> 8), BOX_X2 & 0xFF,
                   BOX_Y1 >> 4, ((BOX_Y1 & 0xF) << 4) | (BOX_Y2 >> 8), BOX_Y2 & 0xFF])
    cmds += struct.pack(">BHH", 0x06, top_off, bottom_off)
    cmds += bytes([0x01, 0xFF])  # start display, end
    assert 4 + len(top) + len(bottom) + len(cmds) == dcsq2

    delay = round(duration * 90000 / 1024)
    cmds += struct.pack(">HH", delay, dcsq2) + bytes([0x02, 0xFF])  # stop display, end

    body = top + bottom + cmds
    return struct.pack(">HH", 4 + len(body), dcsq1) + body


def pts_bytes(pts):
    return bytes([0x21 | ((pts >> 29) & 0x0E),
                  (pts >> 22) & 0xFF, 0x01 | ((pts >> 14) & 0xFE),
                  (pts >> 7) & 0xFF, 0x01 | ((pts << 1) & 0xFE)])


def sector(pts, payload):
    pack = bytes([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01,
                  0x01, 0x89, 0xC3, 0xF8])
    pes_body = bytes([0x81, 0x80, 0x05]) + pts_bytes(pts) + bytes([0x20]) + payload
    pes = bytes([0x00, 0x00, 0x01, 0xBD]) + struct.pack(">H", len(pes_body)) + pes_body
    data = pack + pes
    pad = 2048 - len(data)
    assert pad >= 6
    return data + bytes([0x00, 0x00, 0x01, 0xBE]) + struct.pack(">H", pad - 6) + b"\xFF" * (pad - 6)


def timestamp(t):
    ms = round(t * 1000)
    return "%02d:%02d:%02d:%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        idx_path = os.path.join(tmp, "subs.idx")
        sub_path = os.path.join(tmp, "subs.sub")

        idx = ["# VobSub index file, v7 (do not modify this line!)",
               "size: %dx%d" % (W, H),
               "palette: " + ", ".join(["000000", "ffffff", "ffff00", "00ffff"] + ["000000"] * 12),
               "",
               "id: en, index: 0"]
        with open(sub_path, "wb") as sub:
            for i, (start, duration) in enumerate(CUES):
                idx.append("timestamp: %s, filepos: %09x" % (timestamp(start), sub.tell()))
                sub.write(sector(round(start * 90000), spu(duration, 1 + i % 3)))
        with open(idx_path, "w") as f:
            f.write("\n".join(idx) + "\n")

        subprocess.run([
            FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "smptebars=size=%dx%d:rate=25:duration=%d" % (W, H, DURATION),
            "-i", idx_path,
            "-map", "0:v", "-map", "1:s",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "34", "-g", "25",
            "-c:s", "copy", "-metadata:s:s:0", "language=eng",
            "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact",
            OUT,
        ], check=True)
    print(OUT)


if __name__ == "__main__":
    main()
