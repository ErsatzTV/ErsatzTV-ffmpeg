#!/usr/bin/env bash
#
# Generates samples/hevc-320x240-open-gop-start.mkv: HEVC, 320x240 at 30 fps,
# where the whole picture scrolls ~1.6 px a frame, with open GOPs every 30
# frames, cut so it starts on the second GOP's CRA picture. The RASL picture
# after it references the GOP that was cut off. hevcdec drops it; AMF without
# 0028 outputs it as a concealed picture.
#
# Repeats VPS/SPS/PPS before every keyframe. Needs libx265.
# Usage: make-hevc-open-gop-start.sh [/path/to/ffmpeg]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=4,scroll=h=0.005" \
    -c:v libx265 -preset veryfast -crf 30 \
    -x265-params "keyint=30:min-keyint=30:open-gop=1:bframes=3:scenecut=0:repeat-headers=1:log-level=error" \
    "$tmp/open-gop.mkv"
ff -i "$tmp/open-gop.mkv" -map 0:v -c copy -bsf:v "noise=drop=lt(n\,29)" \
    "$here/hevc-320x240-open-gop-start.mkv"
