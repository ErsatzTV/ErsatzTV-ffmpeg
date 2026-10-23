#!/bin/sh
# Reproducer for 0020-avcodec-videotoolbox-retry-without-requiring-hardware.patch
#
# Intel Macs refuse a hardware H.264 session for streams with more than 10
# reference frames. Without the patch the videotoolbox hwaccel fails to
# initialise, ffmpeg decodes to software frames, and the hwdownload graph
# below can't be configured. With the patch, VideoToolbox decodes in software
# and still outputs videotoolbox_vld frames. Apple silicon accepts the sample
# in hardware, so it passes there with or without the patch.
#
# Usage: videotoolbox-h264-high-refs.sh FFMPEG NEW_OUTPUT_DIR [INPUT]
# INPUT defaults to samples/h264-640x360-ref16.mkv. Output is retained.
set -eu
[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || {
    echo "Usage: $0 FFMPEG NEW_OUTPUT_DIR [INPUT]" >&2; exit 2;
}
here=$(cd "$(dirname "$0")" && pwd)
ffmpeg=$1 out=$2
input=${3:-$here/../samples/h264-640x360-ref16.mkv}
mkdir "$out"
rc=0
"$ffmpeg" -nostdin -hide_banner -loglevel verbose \
    -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld \
    -i "$input" -an -vf hwdownload,format=nv12 -f null - > "$out/decode.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    grep -E 'session not available|Failed setup|Impossible to convert' "$out/decode.log" >&2 || true
    echo "FAIL: VideoToolbox decode exited $rc" >&2; exit 1
fi
frames=$(sed -n 's/.*frame= *\([0-9]*\).*/\1/p' "$out/decode.log" | tail -1)
[ "${frames:-0}" -gt 0 ] || { echo "FAIL: no frames decoded" >&2; exit 1; }
if grep -q 'retrying without requiring hardware' "$out/decode.log"; then
    how="VideoToolbox software decoder"
else
    how="VideoToolbox hardware decoder"
fi
echo "PASS: $frames frames decoded as videotoolbox_vld ($how)"
