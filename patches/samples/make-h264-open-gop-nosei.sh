#!/usr/bin/env bash
# Strip SEI from the existing open-GOP sample without changing its pictures.
# Use NUT: Matroska remuxing loses the first non-IDR I-packet's key flag.
# The reference remains the SEI-bearing sample (90 valid frames). Default
# software decode of this stripped sample drops two valid buffered pictures.
# Usage: make-h264-open-gop-nosei.sh [ffmpeg]
set -euo pipefail
FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$FFMPEG" -nostdin -hide_banner -loglevel error -y \
    -i "$here/h264-320x240-open-gop-start.mkv" -map 0:v -c copy \
    -bsf:v filter_units=remove_types=6 "$here/h264-320x240-open-gop-nosei.nut"
