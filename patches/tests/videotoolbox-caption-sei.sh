#!/bin/sh
# Reproduce the observed VideoToolbox A53 SEI merge failure on macOS.
# Usage: videotoolbox-caption-sei.sh FFMPEG FFPROBE NEW_OUTPUT_DIR [CAPTIONED_INPUT]
# CAPTIONED_INPUT defaults to samples/h264-640x480-a53cc.ts; any local H264 file
# with embedded A53 captions also works. START_SECONDS defaults to 0.
# Output is retained for inspection.
set -eu
[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || {
    echo "Usage: $0 FFMPEG FFPROBE NEW_OUTPUT_DIR [CAPTIONED_INPUT]" >&2; exit 2;
}
here=$(cd "$(dirname "$0")" && pwd)
ffmpeg=$1 ffprobe=$2 out=$3
input=${4:-$here/../samples/h264-640x480-a53cc.ts}
start=${START_SECONDS:-0}
mkdir "$out"
"$ffprobe" -v error -select_streams v:0 -read_intervals "$start%+5" \
    -show_frames -show_entries frame=side_data_list -of json "$input" > "$out/input-frames.json"
caption_count() {
    jq '[.frames[].side_data_list[]? | select(.side_data_type == "ATSC A53 Part 4 Closed Captions")] | length' "$1"
}
[ "$(caption_count "$out/input-frames.json")" -gt 0 ] || {
    echo "Input section has no A53 captions; cannot exercise this failure" >&2; exit 2;
}
"$ffmpeg" -nostdin -hide_banner -loglevel warning -hwaccel videotoolbox \
    -ss "$start" -i "$input" -t 5 -an -c:v h264_videotoolbox \
    -b:v 6000k -a53cc 1 "$out/output.ts" > "$out/encode.log" 2>&1
"$ffmpeg" -nostdin -hide_banner -loglevel warning -i "$out/output.ts" \
    -f null - > "$out/decode.log" 2>&1
if grep -Ei 'SEI|Error|Invalid|corrupt' "$out/encode.log" "$out/decode.log"; then
    echo "FAIL: encoding or decoding reported invalid metadata" >&2; exit 1
fi
"$ffprobe" -v error -select_streams v:0 -show_frames \
    -show_entries frame=side_data_list -of json "$out/output.ts" > "$out/output-frames.json"
count=$(caption_count "$out/output-frames.json")
[ "$count" -gt 0 ] || { echo "FAIL: output lost A53 captions" >&2; exit 1; }
echo "PASS: encode/decode completed without SEI errors; $count output frames carry A53 captions"
