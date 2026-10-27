#!/usr/bin/env bash
#
# Generates samples/mpeg2-320x240-open-gop-dup-pts.mkv: 2 s of MPEG-2 where the
# whole picture scrolls ~1.6 px a frame, cut so it starts on an open GOP. The
# first packet is an I-frame, the second a leading B-frame that references the
# GOP that was cut off, and that B-frame has the same pts as the I-frame. DVD
# rips cut by remuxing can look like this.
# The repeated pts is the timestamp fault that made qsvdec without 0024 time
# every later frame by its dts.
#
# Usage: make-mpeg2-open-gop-dup-pts.sh [/path/to/ffmpeg]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# testsrc, not testsrc2: MPEG-2 can't make testsrc2 small. One B-frame between
# references and no closed GOPs, so packet 15 is the second GOP's I-frame and
# packet 16 its one leading B-frame.
ff -f lavfi -i "testsrc=s=320x240:r=30000/1001:d=2.5,scroll=h=0.005" \
    -c:v mpeg2video -q:v 6 -g 15 -bf 1 \
    "$tmp/full.ts"
ff -i "$tmp/full.ts" -map 0:v -c copy \
    -bsf:v "noise=drop=lt(n\,15),setts=pts=if(eq(N\,1)\,PREV_INPTS\,PTS)" \
    "$here/mpeg2-320x240-open-gop-dup-pts.mkv"
