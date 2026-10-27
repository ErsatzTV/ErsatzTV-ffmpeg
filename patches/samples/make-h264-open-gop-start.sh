#!/usr/bin/env bash
#
# Generates two H.264 samples, 320x240 at 30 fps, where the whole picture
# scrolls ~1.6 px a frame:
#
#   h264-320x240-open-gop-start.mkv: open GOPs every 30 frames, cut so it
#     starts on the second GOP's I-frame (a recovery point, not an IDR). The
#     B-frame after it references the GOP that was cut off. Software decoders
#     drop it; QSV without 0025 outputs it as a concealed picture.
#   h264-320x240-intra-refresh-mid.mkv: periodic intra refresh with no
#     I-frames, cut in the middle of a refresh. Software waits for the next
#     recovery point. It guards 0025 against dropping frames that never stop
#     being marked corrupted.
#
# Both repeat SPS/PPS before every keyframe: with them only in extradata, QSV
# can't start a stream on a non-IDR picture at all, a separate problem.
#
# Needs libx264. Usage: make-h264-open-gop-start.sh [/path/to/ffmpeg]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=4,scroll=h=0.005" \
    -c:v libx264 -preset veryfast -crf 30 \
    -x264-params "keyint=30:min-keyint=30:open-gop=1:bframes=3:scenecut=0:repeat-headers=1" \
    "$tmp/open-gop.mkv"
ff -i "$tmp/open-gop.mkv" -map 0:v -c copy -bsf:v "noise=drop=lt(n\,29)" \
    "$here/h264-320x240-open-gop-start.mkv"

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=6,scroll=h=0.005" \
    -c:v libx264 -preset veryfast -crf 30 \
    -x264-params "keyint=30:intra-refresh=1:bframes=0:repeat-headers=1" \
    "$tmp/intra-refresh.mkv"
ff -i "$tmp/intra-refresh.mkv" -map 0:v -c copy -bsf:v "noise=drop=lt(n\,40)" \
    "$here/h264-320x240-intra-refresh-mid.mkv"
