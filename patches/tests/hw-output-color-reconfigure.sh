#!/usr/bin/env bash
#
# Reproducer for 0032-fftools-ffmpeg_filter-do-not-pin-color-of-hw-outputs.patch
#
# After the first configuration, ffmpeg pins each output's color space and
# range to what the sink negotiated, so a later reconfiguration keeps them.
# When the input's color tags change mid-stream, the reconfigured graph then
# needs a conversion before the output. Only the automatic scale filter can
# convert, and it cannot take hardware frames, so every reconfiguration of a
# graph that ends in hardware frames fails:
#
#   Impossible to convert between the formats supported by the filter
#   'Parsed_scale_vaapi_0' and the filter 'auto_scale_0'
#   Error reinitializing filters!
#
# The test joins a bt709 clip and a smpte170m clip (same size and format),
# decodes with VAAPI, scales with scale_vaapi and encodes with h264_vaapi.
# Hardware decode matters: with software frames in, the conversion fits before
# an hwupload and nothing fails. It passes -noautoscale, as ErsatzTV does:
# without it the reconfiguration also inserts a software scale filter for the
# pinned output size, which fails the same way and is not what this patch
# changes.
#
#   unpatched: exit 218 at the join, 30 of 60 frames
#   patched:   exit 0, 60 of 60 frames
#
# Usage: hw-output-color-reconfigure.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg hw-output-color-reconfigure.sh
#        VAAPI_DEVICE=/dev/dri/renderD129 hw-output-color-reconfigure.sh
#
# Exit: 0 pass, 1 fail, 2 cannot run ffmpeg, 77 h264_vaapi unavailable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

part() { # name colorspace
    ff -f lavfi -i "testsrc2=size=320x240:rate=30:duration=1" -c:v libx264 -g 15 \
        -colorspace "$2" -color_primaries "$2" -color_trc "$2" -f mpegts "$work/$1.ts"
}
if ! part a bt709 || ! part b smpte170m; then
    echo "ERROR: cannot build the input file" >&2
    exit 2
fi
printf "file '%s'\n" "$work/a.ts" "$work/b.ts" > "$work/list.txt"
if ! ff -f concat -safe 0 -i "$work/list.txt" -c copy "$work/in.ts"; then
    echo "ERROR: cannot join the input file" >&2
    exit 2
fi

if ! ff -init_hw_device vaapi=va:"$VAAPI_DEVICE" -filter_hw_device va \
    -f lavfi -i "testsrc2=size=320x240" -frames:v 1 -vf format=nv12,hwupload \
    -c:v h264_vaapi -f null - 2>/dev/null; then
    echo "SKIP: h264_vaapi is not usable on $VAAPI_DEVICE"
    exit 77
fi

"$FFMPEG" -nostdin -hide_banner -loglevel info -y \
    -init_hw_device vaapi=va:"$VAAPI_DEVICE" -filter_hw_device va \
    -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi \
    -i "$work/in.ts" -vf scale_vaapi=320:240 -noautoscale -c:v h264_vaapi \
    -f mpegts "$work/out.ts" \
    2> "$work/log"
status=$?
frames=$(grep -a -o 'frame= *[0-9]*' "$work/log" | tail -1 | tr -dc 0-9)

echo "ffmpeg:  $FFMPEG"
echo "device:  $VAAPI_DEVICE"
echo "result:  exit $status, ${frames:-0} of 60 frames"
grep -a -E 'Reconfiguring|Impossible|Error reinitializing' "$work/log" | sed 's/^/  /'

if [ "$status" -ne 0 ] || [ "${frames:-0}" -lt 60 ]; then
    echo "FAIL: the graph cannot be reconfigured after the color tags change"
    exit 1
fi

echo "PASS: the graph was reconfigured and every frame was encoded"
