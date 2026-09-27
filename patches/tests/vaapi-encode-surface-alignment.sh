#!/usr/bin/env bash
#
# Reproducer for
#   0002-vaapi_encode-query-surface-alignment-regardless-of-libva-build-version.patch
#
# vaapi_encode_surface_alignment() is compiled out when FFmpeg is built against
# libva < 2.21 (VA-API < 1.21), which this repo does on purpose (50-libva.sh pins
# 2.20.0). The encoder then never learns the driver's surface alignment and
# writes an SPS whose picture size is the visible size with no conformance
# window, while the driver codes - and rewrites the header to - the aligned
# size. The stream decodes larger than requested.
#
# Needs a driver that reports VASurfaceAttribAlignmentSize. Mesa radeonsi does,
# but only when mesa itself was built against libva >= 2.21. On a driver that
# does not report it the stream is sized identically with or without the patch,
# so a PASS there proves nothing - the script prints the driver for that reason.
#
# Encodes a few frames of testsrc2 with hevc_vaapi at each size and compares the
# stream's display size (ffprobe, conformance window applied) with the request.
#
#   unpatched: 1920x1080 -> 1920x1088, 1440x1080 -> 1472x1088, 854x480 -> 894x480
#   patched:   every size comes back as requested
#
# Usage: vaapi-encode-surface-alignment.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg vaapi-encode-surface-alignment.sh
#        FFPROBE=/path/to/ffprobe SIZES="1920x1080" vaapi-encode-surface-alignment.sh
#        VAAPI_DEVICE=/dev/dri/renderD129 vaapi-encode-surface-alignment.sh
#
# FFPROBE defaults to the ffprobe next to FFMPEG; the check is on the bitstream,
# so any ffprobe will do.
#
# Exit: 0 all sizes as requested, 1 any size wrong, 77 hevc_vaapi unavailable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
if [ -z "${FFPROBE:-}" ]; then
    FFPROBE="$(dirname "$(command -v "$FFMPEG")")/ffprobe"
    [ -x "$FFPROBE" ] || FFPROBE=ffprobe
fi

SIZES="${SIZES:-1920x1080 1440x1080 854x480}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi
if ! "$FFPROBE" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffprobe: $FFPROBE" >&2
    exit 2
fi

encode() {
    "$FFMPEG" -nostdin -hide_banner -loglevel "$1" -y \
        -init_hw_device vaapi=va:"$VAAPI_DEVICE" -filter_hw_device va \
        -f lavfi -i "testsrc2=size=$2:rate=25" -frames:v 5 \
        -vf format=nv12,hwupload -c:v hevc_vaapi -f hevc "$3"
}

echo "ffmpeg:   $FFMPEG"
echo "ffprobe:  $FFPROBE"
echo "device:   $VAAPI_DEVICE"

if ! encode verbose 1280x720 "$logdir/probe.hevc" >"$logdir/probe.log" 2>&1; then
    echo "SKIP: hevc_vaapi encode failed on $VAAPI_DEVICE" >&2
    tail -5 "$logdir/probe.log" >&2
    exit 77
fi
driver=$(grep -m1 -o 'VAAPI driver: .*' "$logdir/probe.log" || true)
echo "driver:   ${driver#VAAPI driver: }"

fail=0
for size in $SIZES; do
    out="$logdir/$size.hevc"
    if ! encode error "$size" "$out" >"$logdir/$size.log" 2>&1; then
        echo "FAIL: $size: encode failed"
        sed 's/^/      /' "$logdir/$size.log"
        fail=1
        continue
    fi
    got=$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0:s=x "$out")
    if [ "$got" = "$size" ]; then
        echo "PASS: $size -> $got"
    else
        echo "FAIL: $size -> $got"
        fail=1
    fi
done

exit $fail
