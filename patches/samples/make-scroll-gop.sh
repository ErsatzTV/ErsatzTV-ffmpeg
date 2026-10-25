#!/usr/bin/env bash
#
# Generates samples/h264-320x240-scroll-gop30.mkv and
# samples/mpeg2-320x240-scroll-gop15.mkv: 2.5 s where the whole picture
# scrolls ~1.6 px a frame, so pairing a frame with its neighbour drops PSNR to
# ~15 dB. H.264 has B-frames and a keyframe every 30 frames (1 s); MPEG-2 has
# B-frames and open GOPs every 15 frames. A 1.4 s seek leaves 12 frames between
# the keyframe and the seek point, which is what qsvdec without 0022 mistimes.
# Smaller versions of ErsatzTV next's 480p_h264_scroll.mkv / 480p_mpeg2_scroll.mkv.
#
# Needs libx264. Usage: make-scroll-gop.sh [/path/to/ffmpeg]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=2.5,scroll=h=0.005" \
    -c:v libx264 -preset veryfast -crf 30 -g 30 -keyint_min 30 \
    "$here/h264-320x240-scroll-gop30.mkv"
# testsrc, not testsrc2: MPEG-2 can't make testsrc2 small
ff -f lavfi -i "testsrc=s=320x240:r=30000/1001:d=2.5,scroll=h=0.005" \
    -c:v mpeg2video -q:v 6 -g 15 -bf 2 \
    "$here/mpeg2-320x240-scroll-gop15.mkv"
