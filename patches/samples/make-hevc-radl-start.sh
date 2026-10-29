#!/usr/bin/env bash
# Valid HEVC leading pictures: IDR_W_RADL followed in decode order by two
# RADL pictures. Software outputs 62 frames, beginning 0.067 s before the IDR.
# Requires libx265 with radl support. Usage: make-hevc-radl-start.sh [ffmpeg]
set -euo pipefail
FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }
ff -f lavfi -i 'testsrc2=s=320x240:r=30:d=3' \
    -c:v libx265 -preset veryfast \
    -x265-params 'keyint=30:min-keyint=30:open-gop=0:bframes=3:radl=2:scenecut=0:repeat-headers=1:log-level=error:pools=2' \
    "$tmp/full.mkv"
ff -i "$tmp/full.mkv" -c copy -bsf:v 'noise=drop=lt(n\,28)' \
    "$here/hevc-320x240-radl-start.mkv"
