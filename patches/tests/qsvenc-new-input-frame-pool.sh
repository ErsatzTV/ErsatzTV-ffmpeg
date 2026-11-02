#!/usr/bin/env bash
#
# Reproducer for 0033-avcodec-qsvenc-switch-to-a-new-input-frame-pool.patch
#
# When ffmpeg reconfigures a filter graph, vpp_qsv (and overlay_qsv) allocate a
# new output pool. On a fixed-pool runtime (legacy Media SDK, API < 2.9, or
# D3D9) the already-open QSV encoder only knows the surfaces of the first pool,
# so the first frame from the new one fails before it reaches the runtime:
#
#   [h264_qsv] Error submitting the frame for encoding.
#   Error encoding a frame: Internal bug, should not have happened
#
# The test joins a 320x240 and a 352x288 h264 clip, decodes with QSV, scales
# both to 320x240 with vpp_qsv and encodes with h264_qsv. The size change makes
# the decoder reallocate (0013 only keeps its pool when the size is unchanged)
# and fftools rebuilds the graph; the encoder's input size stays the same.
#
# On a oneVPL 2.9+ runtime the pools are dynamic and both builds pass; the
# case is then reported as SKIP. Run it on a legacy-runtime host to verify.
#
#   unpatched: exit 190 (Linux) or 0xdeb8aabe (Windows), about 21 of 60 frames
#   patched:   exit 0, 60 of 60 frames, "switching to it" in the log
#
# Usage: qsvenc-new-input-frame-pool.sh [/path/to/ffmpeg]
#        FFMPEG=/path/to/ffmpeg qsvenc-new-input-frame-pool.sh
#        INIT_HW_DEVICE=qsv=hw,child_device=/dev/dri/renderD129 qsvenc-new-input-frame-pool.sh
#
# Exit: 0 pass, 1 fail, 2 cannot run ffmpeg, 77 h264_qsv unavailable or the
# runtime is unaffected.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
INIT_HW_DEVICE="${INIT_HW_DEVICE:-qsv=hw}"
TIMEOUT="${TIMEOUT:-60}"

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }

part() { # name size
    ff -f lavfi -i "testsrc2=size=$2:rate=30:duration=1" -c:v libx264 -g 15 \
        -pix_fmt yuv420p -f mpegts "$work/$1.ts"
}
if ! part a 320x240 || ! part b 352x288; then
    echo "ERROR: cannot build the input file" >&2
    exit 2
fi
printf "file '%s'\n" "$work/a.ts" "$work/b.ts" > "$work/list.txt"
if ! ff -f concat -safe 0 -i "$work/list.txt" -c copy "$work/in.ts"; then
    echo "ERROR: cannot join the input file" >&2
    exit 2
fi

if ! ff -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
    -f lavfi -i "testsrc2=size=320x240" -frames:v 1 -vf format=nv12,hwupload=extra_hw_frames=16 \
    -c:v h264_qsv -f null - 2>/dev/null; then
    echo "SKIP: h264_qsv is not usable with $INIT_HW_DEVICE"
    exit 77
fi

timeout "$TIMEOUT" "$FFMPEG" -nostdin -hide_banner -loglevel verbose -y \
    -init_hw_device "$INIT_HW_DEVICE" -filter_hw_device hw \
    -hwaccel qsv -hwaccel_output_format qsv \
    -i "$work/in.ts" -vf vpp_qsv=w=320:h=240 -noautoscale -c:v h264_qsv \
    -f mpegts "$work/out.ts" \
    2> "$work/log"
status=$?
frames=$(grep -a -o 'frame= *[0-9]*' "$work/log" | tail -1 | tr -dc 0-9)

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $INIT_HW_DEVICE"
echo "runtime: $(grep -a -o 'implementation version is [0-9.]*' "$work/log" | tail -1)"
echo "result:  exit $status, ${frames:-0} of 60 frames"
grep -a -E 'Reconfiguring|new frame pool|cannot switch|Error submitting|Internal bug' "$work/log" | sed 's/^/  /'

if [ "$status" -ne 0 ] || [ "${frames:-0}" -lt 60 ]; then
    echo "FAIL: the encoder cannot take frames from the rebuilt graph's pool"
    exit 1
fi

if ! grep -a -q 'Reconfiguring filter graph' "$work/log"; then
    echo "SKIP: the graph was never reconfigured, so the input did not exercise the bug"
    exit 77
fi

if ! grep -a -q 'Input frames come from a new frame pool' "$work/log"; then
    echo "SKIP: every frame was encoded without switching pools; this runtime uses dynamic pools and is unaffected"
    exit 77
fi

echo "PASS: the encoder switched to the rebuilt graph's pool and every frame was encoded"
