#!/usr/bin/env bash
#
# Reproducer for 0001-avfilter-video-honor-requested-size-for-hw-frames.patch
#
# ff_default_get_video_buffer2() ignores the requested w/h. A filter that asks
# for a writable buffer of the link size (overlay's in-place blend, via
# ff_inlink_make_frame_writable) gets a frame of the *padded* size instead, and
# that size then propagates downstream as a picture size change.
#
# Two independent halves, and they are fixed independently upstream:
#
#   sw pool path  the link's frame pool is created at the padded size by
#                 hwdownload (which requests hwframes->width/height) and keeps
#                 those dimensions for every later request.
#                 -> cases vaapi-sw-pool, vaapi-hwupload
#
#   hw path       av_hwframe_get_buffer() stamps the frames context's padded
#                 surface size onto the frame, and the rows between the logical
#                 and padded height are never written (green line).
#                 -> case cuda-hw-frames
#
# Only codecs whose coded height differs from the display height are affected:
# 1080p h264 pads to FFALIGN(1080,16)=1088, which is what the sample carries.
# Seeking past the first frame hides the bug (the pool is then created by a
# different request), so none of these cases may use -ss.
#
# Each case is skipped, not failed, when the ffmpeg under test cannot run it
# (no VAAPI device, no CUDA/nvenc, filters not built in).
#
# Usage: avfilter-requested-hw-frame-size.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg avfilter-requested-hw-frame-size.sh
#        CASES="cuda-hw-frames" avfilter-requested-hw-frame-size.sh /path/to/ffmpeg
#        VAAPI_DEVICE=/dev/dri/renderD129 avfilter-requested-hw-frame-size.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/h264-1920x1080-coded-1088.mkv"
overlay="$here/../samples/overlay-320x180.jpg"

EXPECT="${EXPECT:-1920x1080}"
CASES="${CASES:-vaapi-sw-pool vaapi-hwupload cuda-hw-frames}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

logdir="$(mktemp -d)"
trap 'rm -rf "$logdir"' EXIT

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

for f in "$sample" "$overlay"; do
    if [ ! -f "$f" ]; then
        echo "SKIP: sample not found: $f" >&2
        exit 77
    fi
done

pass=0; fail=0; skip=0

# Size of the encoder's input as ffmpeg reports it under "Output #0". This is
# the filtergraph's output link size, so it shows the propagated 1088 without
# needing ffprobe or an output file.
output_size() {
    awk '
        /^Output #/ { out = 1 }
        out && /^ *Stream #.*Video:/ {
            if (match($0, /(^|[ ,]) *[0-9]+x[0-9]+([ ,]|$)/)) {
                s = substr($0, RSTART, RLENGTH)
                gsub(/[^0-9x]/, "", s)
                print s
                exit
            }
        }' "$1"
}

report_skip() {
    echo "SKIP: $1 - $2"
    sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown" "$3" | tail -3)"
    skip=$((skip + 1))
}

# vaapi-sw-pool / cuda-hw-frames: assert the graph's output size.
check_size() {
    local name="$1" log="$2" size
    size="$(output_size "$log")"

    if [ -z "$size" ]; then
        report_skip "$name" "ffmpeg produced no output stream" "$log"
        return
    fi
    if [ "$size" = "$EXPECT" ]; then
        echo "PASS: $name - output is $size"
        pass=$((pass + 1))
    else
        echo "FAIL: $name - output is $size, expected $EXPECT (padded size leaked into the link)"
        fail=$((fail + 1))
    fi
}

run_vaapi_sw_pool() {
    local log="$logdir/vaapi-sw-pool.log"
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -hwaccel vaapi -hwaccel_output_format vaapi -i "$sample" -i "$overlay" \
        -filter_complex "[0:v]hwdownload,format=nv12[v];[v][1:v]overlay[o]" \
        -map "[o]" -c:v rawvideo -f null - >"$log" 2>&1
    check_size vaapi-sw-pool "$log"
}

# The graph ErsatzTV actually runs: the oversized frame is handed back to a
# hwupload whose frames context is the link size, which rejects it outright.
run_vaapi_hwupload() {
    local log="$logdir/vaapi-hwupload.log"
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -init_hw_device "vaapi=va:$VAAPI_DEVICE" -filter_hw_device va \
        -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi \
        -i "$sample" -i "$overlay" \
        -filter_complex "[0:v]hwdownload,format=nv12[v];[v][1:v]overlay[o];[o]format=nv12,hwupload[e]" \
        -map "[e]" -c:v h264_vaapi -f null - >"$log" 2>&1
    local rc=$?

    if grep -q "Failed to upload frame: -22" "$log"; then
        echo "FAIL: vaapi-hwupload - hwupload rejected the frame (-22), it is taller than its frames context"
        fail=$((fail + 1))
    elif [ $rc -ne 0 ]; then
        report_skip vaapi-hwupload "ffmpeg exited $rc for an unrelated reason" "$log"
    elif [ -z "$(output_size "$log")" ]; then
        report_skip vaapi-hwupload "ffmpeg produced no output stream" "$log"
    else
        echo "PASS: vaapi-hwupload - upload accepted, output is $(output_size "$log")"
        pass=$((pass + 1))
    fi
}

# The hw allocation path. overlay_cuda blends in place, so it is the one filter
# in reach that calls ff_inlink_make_frame_writable() on a hardware link.
# Requires a CUDA host; VAAPI has no in-place filter that exercises this.
run_cuda_hw_frames() {
    local log="$logdir/cuda-hw-frames.log"
    "$FFMPEG" -nostdin -hide_banner -nostats -loglevel info \
        -hwaccel cuda -hwaccel_output_format cuda -i "$sample" -i "$overlay" \
        -filter_complex "[0:0]scale_cuda=format=yuv420p[v];[1:0]hwupload_cuda[wm];[v][wm]overlay_cuda[ov]" \
        -map "[ov]" -c:v h264_nvenc -f null - >"$log" 2>&1
    check_size cuda-hw-frames "$log"
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "sample:  $sample"
echo

for case in $CASES; do
    case "$case" in
        vaapi-sw-pool)   run_vaapi_sw_pool ;;
        vaapi-hwupload)  run_vaapi_hwupload ;;
        cuda-hw-frames)  run_cuda_hw_frames ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0
