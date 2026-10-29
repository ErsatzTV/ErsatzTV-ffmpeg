#!/usr/bin/env bash
# Valid MPEG-2 leading B-picture with backward prediction only.
# Red changes to blue at frame 15. The I-picture at frame 16 is blue; the
# leading B-picture (frame 15) references only that future I-picture, not the
# red reference before the cut (verified with -debug mb_type: '<' and skips).
# Marking this GOP closed therefore accurately describes its references.
# The cut must decode bit-exactly as frames 15 onward of the uncut source.
# Requires python3. Usage: make-mpeg2-closed-gop-leading.sh [ffmpeg]
set -euo pipefail
FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }
ff -f lavfi -i 'color=c=red:s=320x240:r=30:d=2,drawbox=c=blue:t=fill:enable=gte(n\,15)' \
    -c:v mpeg2video -g 15 -bf 1 -sc_threshold 1000000000 -q:v 4 \
    -f mpeg2video "$tmp/full.m2v"
python3 - "$tmp/full.m2v" "$tmp/cut.m2v" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_bytes()
sequence = b'\x00\x00\x01\xb3'
second = source.index(sequence, source.index(sequence) + 4)
cut = bytearray(source[second:])
gop = cut.index(b'\x00\x00\x01\xb8')
cut[gop + 7] |= 0x40  # closed_gop, after the 25-bit time_code
Path(sys.argv[2]).write_bytes(cut)
PY
ff -i "$tmp/full.m2v" -vf 'trim=start_frame=15,setpts=PTS-STARTPTS' -f framemd5 "$tmp/full.md5"
ff -i "$tmp/cut.m2v" -f framemd5 "$tmp/cut.md5"
diff "$tmp/full.md5" "$tmp/cut.md5"
ff -fflags +genpts -i "$tmp/cut.m2v" -c copy \
    "$here/mpeg2-320x240-closed-gop-leading.mkv"
