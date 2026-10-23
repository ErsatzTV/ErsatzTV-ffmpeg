#!/usr/bin/env bash
#
# Generates samples/av1-640x360-hdr10-mdcv.mkv: 2 s of synthetic 10-bit AV1
# tagged HDR10 that carries mastering display and content light metadata twice,
# in metadata OBUs and in the Matroska track. Real HDR10 AV1 remuxes look like
# this, and av1_qsv without 0021 attaches the in-band copy next to the
# container's, which fails filter negotiation with "File exists".
#
# libsvtav1 writes the metadata OBUs. The Matroska copy only appears when the
# encoder's input frames already carry the side data, so the stream is encoded
# once to raw OBUs, decoded with libdav1d (which exports it), and encoded again.
#
# Needs libsvtav1 and libdav1d. Usage: make-av1-hdr10-mdcv.sh [/path/to/ffmpeg]

set -euo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/av1-640x360-hdr10-mdcv.mkv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

svt="mastering-display=G(0.265,0.69)B(0.15,0.06)R(0.68,0.32)WP(0.3127,0.329)L(1000,0.005):content-light=1000,400:enable-hdr=1"
enc=(-pix_fmt yuv420p10le -c:v libsvtav1 -preset 10 -crf 40 -g 24 -svtav1-params "$svt")

# frame properties override -color_trc and friends, so tag the frames
"$FFMPEG" -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=s=640x360:r=24:d=2 \
    -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv \
    "${enc[@]}" "$tmp/step1.obu"

"$FFMPEG" -nostdin -hide_banner -loglevel error -y \
    -framerate 24 -c:v libdav1d -i "$tmp/step1.obu" "${enc[@]}" "$out"

echo "wrote $out"
