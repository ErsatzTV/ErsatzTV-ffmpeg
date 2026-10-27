#!/usr/bin/env bash
#
# Generates samples/mpeg2-640x480-a53cc-midgop.ts: MPEG-2 in MPEG-TS with open
# GOPs of 30 frames and A53 captions on every frame (20 cc triplets, 60 bytes),
# cut at the first P-frame so it starts mid-GOP the way a tuned-in broadcast
# does. The decoder skips the 27 pictures before the second GOP's I-frame and
# the two open-GOP B-frames after it, and mpeg12dec without 0023 piles their
# captions onto the next frames it outputs: 1680 bytes on the I-frame and 180
# on the P-frame after it.
#
# The captions come from samples/h264-640x480-a53cc.ts, re-encoded with
# mpeg2video, which writes the frames' A53 side data as picture user data.
#
# Usage: make-mpeg2-a53cc-midgop.sh [/path/to/ffmpeg] [/path/to/ffprobe]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
FFPROBE="${2:-${FFPROBE:-ffprobe}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/mpeg2-640x480-a53cc-midgop.ts"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$FFMPEG" -nostdin -hide_banner -loglevel error -y \
    -i "$here/h264-640x480-a53cc.ts" -map 0:v \
    -c:v mpeg2video -q:v 12 -g 30 -bf 2 -f mpegts "$tmp/full.ts"

# the second packet in decode order is the first P-frame; its TS packet starts
# its PES, and the muxer repeats PAT/PMT often enough to find the program
pos=$("$FFPROBE" -v error -select_streams v:0 -show_entries packet=pos \
    -of csv=p=0 "$tmp/full.ts" | sed -n 2p | cut -d, -f1)
[ $((pos % 188)) -eq 0 ] || { echo "unexpected cut offset $pos" >&2; exit 1; }

tail -c +$((pos + 1)) "$tmp/full.ts" > "$out"
echo "wrote $out"
